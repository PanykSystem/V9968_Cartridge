"""Run the assembled COM with simulated MSX-DOS and System Controller I/O."""

from pathlib import Path
import unittest

from z80 import Z80Machine


ROOT = Path(__file__).resolve().parent
SIGNATURE = b"V9968_TN20K_CARTRIDGE".ljust(32, b"\0")
VERSION = b"V9968_v0.81".ljust(16, b"\0")
VERSION_ADDRESS = 0x7DFF00


class Updater:
    def __init__(self, args="", image=None, *, device=1, file_size=None,
                 erase_accepted=True, erase_blank=True, corrupt_write=False,
                 short_read=False, stuck_busy=False, controller_timeout=False,
                 page_capable=False, page_result_failure=False,
                 corrupt_address=None, controller_timeout_command=None):
        self.cpu = Z80Machine()
        self.cpu.set_memory_block(0x100, (ROOT / "V9968UPD.COM").read_bytes())
        tail = args.encode("ascii")
        self.cpu.set_memory_block(0x80, bytes([len(tail)]) + tail)
        self.cpu.pc = 0x100
        self.cpu.sp = 0xF000
        self.cpu.memory[5] = 0xC9
        self.cpu.set_breakpoint(5)
        self.cpu.set_output_callback(self.output_port)
        self.cpu.set_input_callback(self.input_port)
        self.image = image
        self.file_size = len(image) if file_size is None and image is not None else file_size
        self.device = device
        self.erase_accepted = erase_accepted
        self.erase_blank = erase_blank
        self.corrupt_write = corrupt_write
        self.short_read = short_read
        self.stuck_busy = stuck_busy
        self.controller_timeout = controller_timeout
        self.controller_timeout_command = controller_timeout_command
        self.pending_command = None
        self.page_capable = page_capable
        self.page_result_failure = page_result_failure
        self.corrupt_address = corrupt_address
        self.flash = bytearray(b"\xFF") * 0x800000
        self.flash[VERSION_ADDRESS:VERSION_ADDRESS + 16] = b"old".ljust(16, b"\0")
        self.flash[0x7DFF10:0x7DFF20] = b"\x55" * 16
        self.enabled = False
        self.selected = False
        self.function = False
        self.address = 0
        self.data = 0
        self.busy = 0
        self.pending = 0
        self.result = 0
        self.page_buffer = bytearray(b"\xFF") * 256
        self.page_index = 0
        self.page_length = 1
        self.page_result = 0
        self.erases = []
        self.writes = []
        self.program_ops = []
        self.read_transactions = []
        self.output = []
        self.closed = False
        self.opened_name = None
        self.dta = 0

    def output_port(self, port, value):
        port &= 0xFF
        if port == 0x40:
            self.enabled = value == 0x80
        elif port == 0x41:
            self.selected = value == self.device and self.enabled
        elif port == 0x42:
            self.function = value == 1 and self.selected
        elif 0x43 <= port <= 0x45:
            shift = (port - 0x43) * 8
            self.address = (self.address & ~(0xFF << shift)) | (value << shift)
        elif port == 0x47:
            self.data = value
        elif port == 0x48:
            self.page_buffer[self.page_index] = value
            self.page_index = (self.page_index + 1) & 0xFF
        elif port == 0x49:
            self.page_length = value + 1
        elif port == 0x4A:
            self.page_index = value
        elif port == 0x46:
            assert self.enabled and self.selected and self.function
            self.pending = 1
            self.pending_command = value
            if value == 0:
                self.result = self.flash[self.address]
            elif value == 1:
                self.writes.append(self.address)
                if not self.corrupt_write and self.address != self.corrupt_address:
                    self.flash[self.address] &= self.data
                self.busy = 2
            elif value == 2:
                block = self.address & 0xFF0000
                self.erases.append(block)
                if self.erase_accepted:
                    self.busy = 2
                    if self.erase_blank:
                        self.flash[block:block + 0x10000] = b"\xFF" * 0x10000
            elif value == 4:
                self.result = int(self.busy > 0 or self.stuck_busy)
                self.busy = max(0, self.busy - 1)
            elif value in (5, 6):
                assert self.page_capable, "Page command sent to a legacy FPGA"
                self.page_result = 0
                crosses_page = (self.address & 0xFF) + self.page_length - 1 > 0xFF
                if (self.page_result_failure is True or
                        self.page_result_failure == value or crosses_page):
                    self.page_result = 1
                elif value == 5:
                    self.program_ops.append((self.address, self.page_length))
                    if not self.corrupt_write:
                        for offset in range(self.page_length):
                            address = self.address + offset
                            if address != self.corrupt_address:
                                self.flash[address] &= self.page_buffer[offset]
                    self.busy = 2
                else:
                    self.read_transactions.append((self.address, self.page_length))
                    self.page_buffer[:self.page_length] = self.flash[
                        self.address:self.address + self.page_length]
                self.pending = 1
            else:
                raise AssertionError(f"Unexpected command {value}")

    def input_port(self, port):
        port &= 0xFF
        if port == 0x40:
            if self.pending:
                if (not self.controller_timeout and
                        self.pending_command != self.controller_timeout_command):
                    self.pending -= 1
                return 0xFF
            return 0x7F if self.enabled else 0xFF
        if port == 0x41:
            return (~self.device & 0xFF) if self.selected else 0xFF
        if port == 0x42:
            return 0xFE if self.function else 0xFF
        if port == 0x47:
            assert not self.pending, "Data read before controller completion"
            return self.result
        if port == 0x48:
            assert not self.pending, "Page data read before controller completion"
            value = self.page_buffer[self.page_index]
            self.page_index = (self.page_index + 1) & 0xFF
            return value
        if port == 0x4E:
            return self.page_result
        if port == 0x4F:
            return 0xA1 if self.page_capable else 0xFF
        raise AssertionError(f"Unexpected input port {port:02X}")

    def bdos(self):
        cpu = self.cpu
        if cpu.c == 0:
            return False
        if cpu.c == 2:
            self.output.append(chr(cpu.e))
        elif cpu.c == 0x0F:
            self.opened_name = bytes(cpu.memory[cpu.de:cpu.de + 12])
            cpu.a = 0 if self.image is not None else 0xFF
            if self.image is not None:
                cpu.set_memory_block(cpu.de + 16, self.file_size.to_bytes(4, "little"))
        elif cpu.c == 0x10:
            self.closed = True
            cpu.a = 0
        elif cpu.c == 0x1A:
            self.dta = cpu.de
        elif cpu.c == 0x27:
            position = int.from_bytes(cpu.memory[cpu.de + 33:cpu.de + 37], "little")
            requested = cpu.hl
            count = requested - 1 if self.short_read and position >= 48 else requested
            chunk = self.image[position:position + count]
            cpu.set_memory_block(self.dta, chunk)
            cpu.set_memory_block(cpu.de + 33, (position + len(chunk)).to_bytes(4, "little"))
            cpu.hl = len(chunk)
            cpu.a = int(len(chunk) != requested)
        else:
            raise AssertionError(f"Unexpected BDOS call {cpu.c:02X}")
        return True

    def run(self):
        for tick in range(20000):
            self.cpu.ticks_to_stop = 100000
            event = self.cpu.run()
            self.cpu.set_memory_block(0xFC9E, (tick & 0xFFFF).to_bytes(2, "little"))
            if event & self.cpu._BREAKPOINT_HIT:
                if not self.bdos():
                    assert not self.enabled, "Controller not disabled on exit"
                    return "".join(self.output)
                self.cpu.pc = int.from_bytes(
                    self.cpu.memory[self.cpu.sp:self.cpu.sp + 2], "little")
                self.cpu.sp += 2
        raise AssertionError("COM execution timed out")


class UpdaterTests(unittest.TestCase):
    def image(self, body=b"\x41\xFF\x5A"):
        return SIGNATURE + VERSION + body

    def test_info_and_detection(self):
        for args in ("", " \t "):
            with self.subTest(args=args):
                app = Updater(args)
                text = app.run()
                self.assertIn("Usage: V9968UPD", text)
                self.assertIn("Cfg. Ver: old", text)
                self.assertNotIn("BIOS", text)
                self.assertEqual(app.writes, [])
        for args in ("", "V9968CFG.BIN"):
            app = Updater(args, self.image(), device=2)
            self.assertIn("V9968 Cartridge is not detected.", app.run())
            self.assertIsNone(app.opened_name)

    def test_help_and_removed_options(self):
        for args in ("/H", "/h", "/?", "/C V9968CFG.BIN", "/B V9968CFG.BIN",
                     "/c V9968CFG.BIN", "/b V9968CFG.BIN",
                     "/X", "/H extra", "/HELP", "one.bin two.bin"):
            with self.subTest(args=args):
                app = Updater(args, self.image())
                self.assertIn("Usage: V9968UPD", app.run())
                self.assertIsNone(app.opened_name)
                self.assertEqual(app.erases, [])

    def test_update(self):
        body = b"\x41\xFF\x5A"
        app = Updater(" a:v9968cfg.bin \t", self.image(body))
        self.assertIn("Config data has been updated.", app.run())
        self.assertEqual(app.opened_name, b"\x01V9968CFGBIN")
        self.assertEqual(app.flash[:len(body)], body)
        self.assertEqual(app.erases, [0, 0x7D0000])
        self.assertEqual(app.flash[VERSION_ADDRESS:VERSION_ADDRESS + 16], VERSION)
        self.assertNotIn(1, app.writes)
        self.assertTrue(all(a < len(body) or VERSION_ADDRESS <= a < VERSION_ADDRESS + 16
                            for a in app.writes))
        self.assertTrue(app.closed)
        self.assertIn("Mode    : Legacy byte", "".join(app.output))

    def test_page_mode_programs_partial_pages_and_reports_mode(self):
        body = b"\x41\xFF\x5A"
        app = Updater("V9968CFG.BIN", self.image(body), page_capable=True)
        text = app.run()
        self.assertIn("Mode    : Page accelerated", text)
        self.assertIn("Config data has been updated.", text)
        self.assertEqual(app.flash[:len(body)], body)
        self.assertEqual(app.program_ops, [(0, 3), (VERSION_ADDRESS, 16)])
        self.assertEqual(app.read_transactions, [(0, 3), (VERSION_ADDRESS, 16)])
        self.assertEqual(len(app.program_ops), 2)
        legacy = Updater("V9968CFG.BIN", self.image(body))
        legacy.run()
        self.assertEqual(len(legacy.writes), 2 + sum(value != 0xFF for value in VERSION))
        self.assertLess(len(app.program_ops), len(legacy.writes))

    def test_page_boundaries_and_program_count(self):
        for size in (1, 255, 256, 257, 0x4000, 0x10000, 0x10001):
            with self.subTest(size=size):
                body = bytearray(b"\xFF") * size
                body[0] = 0x41
                body[-1] = 0x5A
                app = Updater("V9968CFG.BIN", self.image(body), page_capable=True)
                self.assertIn("Config data has been updated.", app.run())
                self.assertEqual(app.flash[:size], body)
                expected_pages = (size + 255) // 256
                body_programs = 1 if size <= 256 else 2
                self.assertEqual(len(app.program_ops), body_programs + 1)
                self.assertEqual(len(app.read_transactions), expected_pages + 1)
                for address, length in app.program_ops[:-1]:
                    self.assertLessEqual((address & 0xFF) + length, 256)

    def test_dense_page_program_reduction(self):
        body = bytes(index % 255 for index in range(0x10001))
        app = Updater("V9968CFG.BIN", self.image(body), page_capable=True)
        self.assertIn("Config data has been updated.", app.run())
        self.assertEqual(app.flash[:len(body)], body)
        self.assertEqual(app.program_ops[:-1],
                         [(address, min(256, len(body) - address))
                          for address in range(0, len(body), 256)])
        self.assertEqual(len(app.read_transactions), 258)
        legacy = Updater("V9968CFG.BIN", self.image(body[:256]))
        self.assertIn("Config data has been updated.", legacy.run())
        self.assertEqual(sum(address < 256 for address in legacy.writes), 256)
        self.assertEqual(app.program_ops[0], (0, 256))

    def test_page_command_failures_are_reported(self):
        for command, message in (
                (5, "Write error"),
                (6, "ConfigROM read error")):
            with self.subTest(command=command):
                app = Updater("V9968CFG.BIN", self.image(b"\x41"),
                              page_capable=True,
                              controller_timeout_command=command)
                self.assertIn(message, app.run())
                self.assertNotIn(0x7D0000, app.erases)
        app = Updater("V9968CFG.BIN", self.image(b"\x41"),
                      page_capable=True, page_result_failure=6)
        self.assertIn("Page transfer rejected (result=01h).", app.run())
        self.assertNotIn(0x7D0000, app.erases)

    def test_page_result_failure_and_corruption_keep_version(self):
        app = Updater("V9968CFG.BIN", self.image(b"\x41"),
                      page_capable=True, page_result_failure=True)
        text = app.run()
        self.assertIn("Page transfer rejected (result=01h).", text)
        self.assertNotIn(0x7D0000, app.erases)
        self.assertEqual(app.flash[VERSION_ADDRESS:VERSION_ADDRESS + 16],
                         b"old".ljust(16, b"\0"))

        body = bytearray(b"\xFF") * 0x4001
        body[0x4000] = 0x42
        app = Updater("V9968CFG.BIN", self.image(body), page_capable=True,
                      corrupt_address=0x4000)
        text = app.run()
        self.assertIn(
            "Verify error at 004000h: expected 42h, read FFh (last SR1=00h).",
            text)
        self.assertEqual(app.flash[VERSION_ADDRESS:VERSION_ADDRESS + 16],
                         b"old".ljust(16, b"\0"))

        app = Updater("V9968CFG.BIN", self.image(b"\x41"),
                      page_capable=True, corrupt_write=True)
        text = app.run()
        self.assertIn(
            "Verify error at 000000h: expected 41h, read FFh (last SR1=00h).",
            text)
        self.assertEqual(app.flash[VERSION_ADDRESS:VERSION_ADDRESS + 16],
                         b"old".ljust(16, b"\0"))

    def test_invalid_images_do_not_erase(self):
        cases = [
            b"",
            self.image()[:47],
            b"Y8960_TP25K_CARTRIDGE".ljust(32, b"\0") + VERSION + b"A",
            SIGNATURE[:-1] + b"X" + VERSION + b"A",
            SIGNATURE + VERSION,
        ]
        for image in cases:
            with self.subTest(image=image[:32]):
                app = Updater("V9968CFG.BIN", image)
                text = app.run()
                self.assertTrue("not a valid V9968 Config image" in text
                                or "Invalid data size" in text)
                self.assertEqual(app.erases, [])
                self.assertTrue(app.closed)
        for size in (0x7D0000 + 49, 0x1000000 + 48):
            app = Updater("V9968CFG.BIN", self.image(), file_size=size)
            self.assertIn("Invalid data size", app.run())
            self.assertEqual(app.erases, [])
        app = Updater("V9968CFG.BIN", self.image(), file_size=0x7D0000 + 48,
                      erase_accepted=False)
        self.assertIn("Erase was not accepted", app.run())
        self.assertEqual(app.erases, [0])

    def test_missing_file(self):
        app = Updater("MISSING.BIN")
        self.assertIn("Cannot open the file", app.run())
        self.assertEqual(app.erases, [])

    def test_failures_leave_version_unchanged(self):
        cases = [
            ({"erase_accepted": False}, "Erase was not accepted (BUSY never set, SR1=00h)"),
            ({"erase_blank": False}, "Erase check failed at 000000h: read 00h (last SR1=00h)"),
            ({"corrupt_write": True}, "Verify error at 000000h: expected 41h, read FFh (last SR1=00h)"),
            ({"short_read": True}, "File read error"),
            ({"stuck_busy": True}, "Erase error"),
            ({"controller_timeout": True}, "Erase error"),
        ]
        for options, message in cases:
            with self.subTest(options=options):
                app = Updater("V9968CFG.BIN", self.image(), **options)
                app.flash[0] = 0
                self.assertIn(message, app.run())
                self.assertNotIn(0x7D0000, app.erases)
                self.assertEqual(app.flash[VERSION_ADDRESS:VERSION_ADDRESS + 16],
                                 b"old".ljust(16, b"\0"))
                self.assertTrue(app.closed)

    def test_chunk_and_block_boundaries(self):
        body = bytearray(b"\xFF") * 0x10001
        for address in (0, 0x3FFF, 0x4000, 0xFFFF, 0x10000):
            body[address] = address & 0x7F
        app = Updater("V9968CFG.BIN", self.image(body))
        self.assertIn("Config data has been updated.", app.run())
        self.assertEqual(app.flash[:len(body)], body)
        self.assertEqual(app.erases, [0, 0x10000, 0x7D0000])

    def test_supplied_header(self):
        self.assertEqual((ROOT / "config" / "header.bin").read_bytes()[:32], SIGNATURE)
        image = (ROOT / "config" / "V9968CFG.BIN").read_bytes()
        self.assertEqual(image[:48], (ROOT / "config" / "header.bin").read_bytes())
        self.assertEqual(image[48:], (ROOT / "config" / "tangnano20k_vdp_cartridge.bin").read_bytes())


if __name__ == "__main__":
    unittest.main()
