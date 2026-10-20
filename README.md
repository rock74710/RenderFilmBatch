# RenderFilm Batch

把整個資料夾的照片用同一組色彩設定一次輸出的 macOS App。影像處理核心在 `Sources/RFCore`。

> **聲明**：RenderFilm Batch 是非官方的個人專案，與 Kodak、Fujifilm 及任何相機或底片廠商皆無關聯、未獲認可。底片風格是以學習與參考為目的的近似詮釋，提到的品牌名稱為各自所有者的商標。

## 環境需求

- macOS 14 以上、Apple Silicon。
- Xcode（含 Metal Toolchain）。若 shader 編譯失敗，先跑 `xcodebuild -downloadComponent MetalToolchain`。

## 建置

```bash
./Scripts/make-batch-app.sh      # 產生 build/RenderFilmBatch.app
open build/RenderFilmBatch.app
```

## 流程

1. **輸入照片** 選資料夾。支援 RAW／JPEG／HEIC；JPEG／HEIC 以 SDR 解碼。
2. **輸出資料夾** 選位置；可勾「略過已存在的輸出」。
3. 右側設定色彩基調、底片風格、顆粒、白平衡、曲線與曝光。
4. 底片條切換預覽照片；⌘ 點選加選、⇧ 點選選範圍。
5. **開始批次處理**；可設定同時處理張數，隨時取消。

## 曝光

- 逐張自動 EV、場景測光（臉、主體、天空分開測）。
- **設為亮度參考** 後「匹配選取／匹配全部」，讓相似照片亮度一致；可復原上次匹配。
- 每張可另加 ±3 EV 曝光補償。

## 輸出

- 格式：HEIC、JPEG、PNG、TIFF；可選 HDR（Rec.2020 PQ／HLG）。
- 尺寸：原始、長邊像素或百分比。長邊上限 32768 px。
- ML 超解析度（Real-ESRGAN 2×，HDR 不適用）與 RAW 降噪。

## 會寫在原圖旁的檔案

逐張曲線存成 `<照片>.rfcurve.xml`，逐張曝光調整也存在原圖旁。原圖所在資料夾唯讀時會在狀態列提示存檔失敗。

## 授權

程式碼採 MIT（[`LICENSE`](LICENSE)）。隨附的 Lensfun 資料（CC BY-SA 3.0）與 ML 模型各自保留原授權，見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
