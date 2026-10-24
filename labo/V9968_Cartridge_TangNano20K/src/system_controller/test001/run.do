onerror {quit -code 1}
onbreak {if {[examine -radix unsigned /tb/test_passed] == 1} {quit -code 0 -f} else {quit -code 1 -f}}
onfinish stop
run -all
if {[examine -radix unsigned /tb/test_passed] != 1} {quit -code 1 -f}
quit -code 0 -f
