# Shepherd の .app バンドルを SwiftPM 成果物から組み立てる。
# Xcode プロジェクトは持たず、swift build + 手組みバンドル + ad-hoc 署名で完結させる。

APP := dist/Shepherd.app
BINARY := .build/release/Shepherd
# SPM が resources 宣言から生成するバンドル。Bundle.module は実行時に
# Bundle.main.resourceURL (= Contents/Resources) からこれを探すため、
# .app へ同梱しないとリソース参照 (AgentIcons) が fatalError で落ちる。
RESOURCE_BUNDLE := .build/release/Shepherd_Shepherd.bundle
# アプリアイコン。生成物の .icns をツリーに置き、app はコピーするだけにする
# (デザインは滅多に変わらないので毎ビルド再描画しない)。
# デザインを変えたら Support/GenerateAppIcon.swift を編集して make icon。
# PNG は README 掲載用で、icns と同時に同じソースから再生成する。
# Support/StatusIcons/ は README の凡例用に、メニューバーの状態アイコンを
# GenerateStatusIcons.swift で書き出したもの。これも make icon で再生成する。
ICNS := Support/AppIcon.icns
ICON_PNG := Support/AppIcon.png
ICONSET := .build/AppIcon.iconset
STATUS_ICONS := Support/StatusIcons
# README 用スクリーンショット。アプリ自身の --render-screenshots モード
# (ScreenshotRenderer) がモックデータの MenuPanel をヘッドレスで描画する。
SCREENSHOTS := Support/Screenshots

.PHONY: app build icon screenshots run clean

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Shepherd
	cp -R $(RESOURCE_BUNDLE) $(APP)/Contents/Resources/
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	cp Support/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

icon:
	rm -rf $(ICONSET)
	swift Support/GenerateAppIcon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)
	cp $(ICONSET)/icon_256x256.png $(ICON_PNG)
	rm -rf $(ICONSET)
	swift Support/GenerateStatusIcons.swift $(STATUS_ICONS)

screenshots: build
	$(BINARY) --render-screenshots $(SCREENSHOTS)

build:
	swift build -c release

run: app
	open $(APP)

clean:
	rm -rf .build dist
