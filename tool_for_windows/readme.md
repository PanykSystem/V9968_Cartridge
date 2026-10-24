# V9968UPD for Windows
USBで繋げた TangNano20K に V9968デザインを書き込むツール。

# 概要
C# で出来た GUI アプリケーションです。
ウィザード形式になっており、下記の順番で質問してくるので、順に従って操作すれば書き込むことができます。

## 1. 更新ファイルの選択
ファイルのパスの入力欄と、その右にファイル選択ダイアログを標示するボタンがあります。
リリースされている V9968 のデザインの V9968CFG.BIN を選択してください。
パス入力欄にパスを入力してもいいし、そこにファイルをドロップすることでパスを入力することもできます。あるいは、ファイル選択ダイアログ表示ボタンをクリックしてその中から選択してください。

その後に、下にある次へボタンをクリックすると、そのファイルが存在するかチェックし、かつ正しいファイルかチェックして、正しければ次へ進めます。
誤っていれば進めません。

## 2. 書込み画面
V9968 Cartridge を接続してください、と表示されるので、接続します。
接続後に、下にある次へボタンをクリックすると、接続チェックが走り、
接続されていなければ進めません。

## 3. 書込み
書込み開始ボタンをクリックすると書き込みを開始します。
progress bar が表示され、消去と書き込みのプロセスすべて合わせて 100% の表示になるようなバーになっています。
100% になると完了です。完了すると、「書き込みが正常に完了しました」と表示されます。
エラーが発生すると、V9968UPD.COM と同じようにエラーメッセージが表示されます。

V9968UPD.COM と同様にバージョン情報も書き込みます。

progress bar の下には、書き込むバージョンが表示されています。
書き込みが正常に完了すると、この表示は「書き込んだバージョン」に変わります。

書き込みが完了すると、下の完了ボタンがクリックできるようになり、
クリックするとウィザードが終了します。

# 注意事項
GOWIN Programmer と、GOWIN のドライバーがインストールされている必要があります。

GOWIN Programmer CLI が必要です。GOWIN Programmer がインストールされていれば入っています。
このツールは、一般的なインストールパスを検索して探しに行きますが、見つからない場合は、GOWIN Programmer CLI のパスを聴く UI が出てきます。ユーザーはその UI で正しいパスを指定する必要があります。

# 実装メモ
## 構成
	V9968UpdWin.sln          Visual Studio 2022 ソリューション
	V9968UpdWin\             C# (WinForms, .NET Framework 4.7.2) プロジェクト
	build.bat                Release ビルドし、V9968UpdWin.exe をこのフォルダへコピーする

.NET Framework 4.7.2 は Windows 10/11 に標準で入っているため、V9968UpdWin.exe 単体で動作します。

## ビルド
	build.bat

または Visual Studio 2022 で V9968UpdWin.sln を開いてビルドします。

## programmer_cli の検索
次の順に探し、最初に見つかったものを使用します。
- 前回指定したパス (%LOCALAPPDATA%\V9968UpdWin\programmer_cli_path.txt)
- 環境変数 PATH
- 各ドライブおよび Program Files 以下の Gowin\<バージョン>\Programmer\bin\programmer_cli.exe (新しいバージョンを優先)

接続確認画面の「CLI の変更...」から後で変更することもできます。

## 書込み処理
V9968CFG.BIN のヘッダ (シグネチャ 32byte + バージョン 16byte) を確認した後、
programmer_cli を次の順に実行します。JTAG クロックは 2.5MHz です。

1. Config data 本体 (ヘッダ +48 以降) を ConfigROM の 000000h- へ書き込む
	programmer_cli --device GW2AR-18C --frequency 2.5MHz --run 39 --fsFile config.bin --spiaddr 0x000000
	(exFlash C Bin Erase,Program,Verify thru GAO-Bridge)
	GOWIN Programmer GUI で .fs を書き込む際の「exFlash Erase,Program thru GAO-Bridge」(36) と
	同じ GAO-Bridge 経由のアクセスで、ヘッダ除去済みの .bin をそのまま書き込みます。
	(通常方式の --run 32 では Verify 後に "Error: Error found!" となり書き込めなかった)
2. 1 が成功した場合だけ、バージョン領域 7D0000h-7DFFFFh を書き込む
	全 FFh の 64KB の 7DFF00h- の位置に 16byte のバージョン情報を置いたものを
	--spiaddr 0x7D0000 で書き込む (消去・書込み・ベリファイ)
3. FPGA を ConfigROM から再起動する (--run 1 Reprogram)
	失敗した場合は、USB ケーブルの抜き差しを促すメッセージを表示します。

ファイル検査のエラーは V9968UPD.COM と同じ文言です。
- Cannot open the file.
- This file is not a valid V9968 Config image.
- Invalid data size. (Config data 本体が 1-7D0000h byte の範囲外)

書込み失敗時は、失敗した工程に応じて Erase error. / Write error. / Verify error. と
programmer_cli の出力末尾を表示します。Config data の書込みに失敗した場合は、
V9968UPD.COM と同様にバージョン領域を更新しません。

## 進捗表示
programmer_cli の出力から工程 (Erasing / Programming / Verifying) と % 表示を読み取り、
Config data 0-88%、バージョン情報 88-97%、再起動 97-100% に割り当てています。
% が出力されない工程では、経過時間から推定した値で進めます。

## 制限事項
- programmer_cli の通常の操作には外部 Flash を読み出してファイルに保存するものが無いため、
  ConfigROM に書き込まれている現在のバージョンは表示しません。
- --run 39 による Config data とバージョン情報の書込みは実機で確認済みです。
- 書込みに失敗した場合は、GOWIN Programmer GUI の「exFlash Erase,Program thru GAO-Bridge」で
  .fs を書き込んで復旧してください。
