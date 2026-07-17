# Shepherd の .app バンドルを SwiftPM 成果物から組み立てる。
# Xcode プロジェクトは持たず、swift build + 手組みバンドルで完結させる。
# ローカル開発は ad-hoc 署名・現行アーキのみ。リリース (CI) は
# ARCHS / SIGN_IDENTITY / VERSION を渡して universal + Developer ID にする
# (.github/workflows/release.yml が呼び出し元)。

APP := dist/Shepherd.app
ZIP := dist/Shepherd.zip

# 署名 identity。既定の "-" は ad-hoc。リリースでは
# SIGN_IDENTITY="Developer ID Application" (部分一致で解決される) を渡す。
# Developer ID のときだけ hardened runtime + secure timestamp を付ける。
# 両方とも公証 (notarytool) の必須条件で、逆に ad-hoc へ --timestamp を
# 付けるとタイムスタンプサーバーへの署名要求が通らず codesign が失敗する。
SIGN_IDENTITY := -
ifeq ($(SIGN_IDENTITY),-)
CODESIGN_FLAGS :=
else
CODESIGN_FLAGS := --options runtime --timestamp
endif

# ビルド対象アーキテクチャ。空 (既定) なら現行アーキのみ。
# リリースでは ARCHS="arm64 x86_64" で universal binary にする。
# --arch を 1 つでも渡すと SwiftPM は成果物を .build/release ではなく
# .build/apple/Products/Release に置くため、BUILD_DIR ごと切り替える。
ARCHS :=
ifeq ($(ARCHS),)
BUILD_DIR := .build/release
ARCH_FLAGS :=
else
BUILD_DIR := .build/apple/Products/Release
ARCH_FLAGS := $(foreach arch,$(ARCHS),--arch $(arch))
endif

BINARY := $(BUILD_DIR)/Shepherd
# SPM が resources 宣言から生成するバンドル。Bundle.module は実行時に
# Bundle.main.resourceURL (= Contents/Resources) からこれを探すため、
# .app へ同梱しないとリソース参照 (AgentIcons) が fatalError で落ちる。
RESOURCE_BUNDLE := $(BUILD_DIR)/Shepherd_Shepherd.bundle

# リリースバージョン。指定時のみ、.app へコピーした後の Info.plist の
# CFBundleShortVersionString / CFBundleVersion を書き換える (ツリー側の
# Support/Info.plist は触らない)。CI がタグ v1.2.3 から "1.2.3" を渡す。
VERSION :=
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

.PHONY: app zip build icon screenshots run clean

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Shepherd
	cp -R $(RESOURCE_BUNDLE) $(APP)/Contents/Resources/
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	cp Support/Info.plist $(APP)/Contents/Info.plist
ifneq ($(VERSION),)
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION)" \
		$(APP)/Contents/Info.plist
endif
	codesign --force --sign "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) $(APP)

# 配布用 zip。plain zip はリソースフォークや署名のメタデータを落として
# Gatekeeper 検証を壊すことがあるため、ditto -c -k で作る。
zip: app
	ditto -c -k --keepParent $(APP) $(ZIP)

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
	swift build -c release $(ARCH_FLAGS)

run: app
	open $(APP)

clean:
	rm -rf .build dist
