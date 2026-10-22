# RenderFilm Batch 0.1.2

更新 RFCore，改善預覽回應、參考亮度匹配與鏡頭校正的資源使用。

- 重用 JPEG／HEIC 渲染器與預覽來源，減少重複初始化和解碼。
- 連續調整時優先處理最新預覽，避免過期結果覆蓋目前畫面。
- 參考亮度匹配重用不隨曝光改變的分析，減少重複工作。
- 單階段鏡頭校正由三張全圖緩衝減為兩張。預覽來源快取最多兩筆、估計解碼容量 384 MiB；匹配與匯出前會釋放。

固定 24MP 人工 JPEG／HEIC 的測試中，亮度匹配由約 1.95 秒縮短至 0.49 秒；同圖同設定的重複預覽由約 214–237 毫秒縮短至 0.6–0.7 毫秒。這些數字不代表拖動任意參數或所有 RAW／人像的速度；尚未證明整個 App 的記憶體峰值穩定下降。

驗證：86 項相關測試有通過證據；五組穩定原版／新版影像比較的最大像素差均為 0。另完成 Release 建置、Developer ID 簽名與 Apple 公證。

**需求**：macOS 14 以上、Apple Silicon。

下載 `RenderFilmBatch-0.1.2.zip`，解壓縮後以新版 App 取代舊版；更新前請先結束正在執行的 App。

---

Updates RFCore for faster preview reuse, reference-brightness matching, and more efficient lens-correction buffers.

- Reuses the JPEG/HEIC renderer and preview sources to reduce repeated initialization and decoding.
- Prioritizes the latest preview request and prevents stale results from replacing the current view.
- Reuses exposure-independent analysis during reference-brightness matching.
- Uses two full-image buffers instead of three for single-stage lens correction. The preview source cache retains at most two entries with a 384 MiB estimated decoded-size budget and is released before matching or export.

In a fixed synthetic 24MP JPEG/HEIC benchmark, brightness matching decreased from about 1.95 s to 0.49 s. Repeated previews of the same image with unchanged settings decreased from about 214–237 ms to 0.6–0.7 ms. These figures do not represent arbitrary slider changes or all RAW/portrait workloads. A consistent reduction in overall app peak memory has not been established.

Validation: 86 distinct related tests have passing evidence; five stable before/after image comparisons had a maximum pixel difference of zero. Release build, Developer ID signing, and Apple notarization completed.

**Requires** macOS 14 or later on Apple Silicon.

Download `RenderFilmBatch-0.1.2.zip`, extract it, and replace the previous app. Quit the running app before updating.
