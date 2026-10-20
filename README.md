# RenderFilm Batch

**繁體中文** | [English](README.en.md)

把整個資料夾的照片用同一組色彩設定一次輸出的 macOS App。RAW 也能直接丟進來，套好底片風格、統一亮度，再批次輸出。

> **聲明**：RenderFilm Batch 是非官方的個人專案，與 Kodak、Fujifilm 及任何相機或底片廠商皆無關聯、未獲認可。底片風格是以學習與參考為目的的近似詮釋，提到的品牌名稱為各自所有者的商標。

## 亮點

- **一次調好，整批套用**：一組設定處理整個資料夾，RAW／JPEG／HEIC 混在一起也可以。
- **整組照片亮度一致**：逐張自動 EV，臉、主體、天空分開測光；指定一張當亮度參考，其他照片自動對齊。
- **底片感**：Natural／Chrome／Negative 色彩基調，加上 6 種底片風格與顆粒。
- **完全在本機處理**：Metal GPU 運算，照片不會上傳。
- **輸出不打折**：HEIC、JPEG、PNG、TIFF，可選 HDR（Rec.2020 PQ／HLG），可用 Real-ESRGAN 放大 2 倍。

## 功能

### 色彩
- 色彩基調：Natural、Chrome、Negative。
- 底片風格：MonoS、MonoH、Cinema、Classic Cinema、Mainichi、Gold。
- 顆粒，可調強度。
- 白平衡：Auto、日光、陰天、陰影、鎢絲燈、日光燈、閃光燈、自訂。
- RGB 曲線，可分 R／G／B 色版調整；逐張曲線存在原圖旁的 `<照片>.rfcurve.xml`。

### 曝光
- 逐張自動 EV、場景測光（臉、主體、天空分開測）。
- 相似照片統一 EV。
- **設為亮度參考** 後「匹配選取／匹配全部」，讓相似照片亮度一致；可復原上次匹配。
- 每張可另加 ±3 EV 曝光補償。

### 人像與修正
- 膚色調整、磨皮，可分級調整。
- 自動拉正水平。
- RAW 降噪。

### 輸出
- 格式：HEIC、JPEG、PNG、TIFF，可調品質。
- HDR 輸出：Rec.2020 PQ 或 HLG。
- 尺寸：原始、長邊像素或百分比，長邊上限 32768 px。
- ML 超解析度（Real-ESRGAN 2×，HDR 不適用）。
- 可設定同時處理張數、略過已存在的輸出、隨時取消。

### 操作
- 底片條切換預覽；⌘ 點選加選、⇧ 點選選範圍。
- 介面支援繁體中文與英文。

## 下載

到 [Releases](../../releases) 下載 `RenderFilmBatch-<版本>.zip`，解壓後拖進「應用程式」，雙擊開啟。

需求：macOS 14 以上、Apple Silicon。

## 使用流程

1. **輸入照片** 選資料夾。
2. **輸出資料夾** 選位置。
3. 在右側調整色彩基調、底片風格、顆粒、白平衡、曲線與曝光。
4. 用底片條檢查各張預覽。
5. 按 **開始批次處理**。

## 自行建置

需要 Xcode（含 Metal Toolchain）。如果 shader 編譯失敗，先執行 `xcodebuild -downloadComponent MetalToolchain`。

```bash
./Scripts/make-batch-app.sh      # 產生 build/RenderFilmBatch.app
open build/RenderFilmBatch.app
```

## 授權

程式碼採 MIT（[`LICENSE`](LICENSE)）。隨附的 Lensfun 資料（CC BY-SA 3.0）與 ML 模型各自保留原授權，見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
