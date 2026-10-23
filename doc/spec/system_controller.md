# System Controller の仕様
	V9968 Cartridge には SerialSRAM はなく、起動時コピーは行わない。
	System Controller は WAIT を出さない。既存の SDRAM 初期化中の WAIT 制御は変更しない。

	I/O の 40h-4Fh に接続されている。
	40h に 128=80h を書き込んだ場合に有効化される。有効化されるまでは、40-4Fh へのリードアクセスに
	対して、応答を返さない。

	|I/Oアドレス|意味|
	|---|---|
	|40h|イネーブラ|
	|41h|デバイスセレクト|
	|42h|ファンクションセレクト|
	|43h-4Fh|ファンクションによって意味が変化する|

	有効化されると、40h のリードは 80h の反転である 7Fh を返す。
	MSX上で動作するプログラムは、7Fh が読めたことで System Controller の存在を認識する。

	System Controller が有効な状態で、41h に書き込む値はデバイスセレクトである。
	41h へ書き込む値(ID)は、下記の意味を持つ。

	|41h へ書き込む値(ID)|意味|
	|---|---|
	|00h|N/A|
	|01h|V9968 Cartridge|
	|02h|Y8960 Cartridge|
	|03h|FPGA MSXtR CPU Board|
	|04h|FPGA MSXtR VDP Board|
	|05h|FPGA MSXtR SND Board|
	|06h-FEh|Reserved|
	|FFh|N/A|

	該当するデバイスは、System Controller が有効な時に 41h に自身の ID が書き込まれると、
	41h リードでその ID の全ビット反転を返すようになる。
	自身の ID ではない場合は、リードに応答を返さない。
	（別のデバイスが応答するので、バス競合を避けるため）

	このプロジェクトは、V9968 Cartridge なので、01h だけをサポートしている。

# V9968 System Controller ファンクション

	|42h へ書き込む値(ID)|意味|
	|---|---|
	|00h|N/A|
	|01h|Config ROM Reader/Writer|
	|02h-FFh|N/A|

	System Controller が有効で、かつ 41h に 01h が書き込まれている状態では、
	I/O 42h に 01h が書き込まれた後に、I/O 42h を読み出すと FEh が返る。
	I/O 42h に 01h 以外が書き込まれた後に、I/O 42h を読み出すと、FFh が返る。
	System Controller が無効または、
	System Controller が有効で 41h に 01h以外が書き込まれている状態では、
	I/O 42h の読み出しには応答しない。

# Config ROM Reader/Writer
	I/Oアドレス 43h-4Fh は下記のように変化する。

	|I/Oアドレス|意味|
	|---|---|
	|43h|Address最下位8bit|
	|44h|Address中位8bit|
	|45h|Address最上位8bit|
	|46h|コマンド|
	|47h|データ|
	|48h-4Fh|Reserved|

	Reserved への読み書きは応答しない。
	コマンドは下記のものがある。

	|コマンド|意味|
	|---|---|
	|00h|読み出し|
	|01h|書き込み|
	|02h|セクター消去|
	|03h|チップ消去|
	|04h|ステータス読み出し|
	|05h-FFh|Reserved|

	読み出し(00h)/ステータス読み出し(04h) の結果は、コマンド完了後に 47h から読み出せる。
	ステータス読み出しでは、ConfigROM のステータスレジスタ1 が読み出され、bit0 が BUSY である。
	書き込み(01h)/セクター消去(02h)/チップ消去(03h) はコマンドを発行するのみであり、
	完了は MSX 側からステータス読み出しを繰り返し、BUSY=0 になったことで確認する。
	セクター消去は 64KB 単位 (アドレス下位 16bit は無視) である。
	46h の読み出しは FFh を返す。Reserved のコマンドは無視される。
	コマンド実行中 (数μs) は、System Controller への I/O アクセスは受け付けられない (WAIT は出ない)。
	46h にコマンドを書いた後は、40h が 7Fh を返すまでリードを繰り返してから次のアクセスを行うこと。
	実行中の書き込みも無視され、完了後に再実行されることはない。VDP/geo3d は通常どおり利用できる。
	チップ消去は FPGA のコンフィグレーションデータも含めて消去するため、使用時は注意すること。

# FPGA 接続
	System Controller のバスクロックは clk85m、SPI の clk_serial は clk215m を使う。
	クロック間転送は要求/応答を 2段 FF で同期し、データは応答まで保持する。
	SPI 側のリセット解除は clk215m に同期させる。
	ConfigROM は BANK3 に接続されている。ポート名とピン番号は下記のとおり。
	Gowin の配置配線設定で「Use MSPI as Regular IO」を有効にし、
	コンフィグレーション完了後はユーザーロジックから MSPI ピンを制御する。

	|ポート名|FPGA ピン番号|意味|
	|---|---|---|
	|mspi_cs|60|Flash CS (Active Low)|
	|mspi_clk|59|Flash CLK|
	|mspi_hold|63|Flash HOLD (Active Low)|
	|mspi_wp|57|Flash WP (Active Low)|
	|mspi_do|62|Flash DO / IO1 (Flash → FPGA)|
	|mspi_di|61|Flash DI / IO0 (FPGA → Flash)|

# シミュレーション
	src/system_controller の各 test ディレクトリで run.bat を実行する (ModelSim が必要)。

	|テスト|確認内容|
	|---|---|
	|test001|BUSY 中の読み書き無視、レジスタ保持、SPI コマンド列、Reserved コマンド|
	|test002|msx_slot の 40h-4Fh と 88h/98h デコード、バス解放、BUSY 中の既存ポート利用|
	|test003|Flash モデルでの読み書き・64KB 消去・チップ消去・ステータス、40h ポーリング|
