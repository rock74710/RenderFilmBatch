# Third-Party Notices

RenderFilm 原始碼採 MIT 授權（見 `LICENSE`）。以下第三方模型與資料**不**適用 MIT，各自保留原授權；完整授權全文放在 `Sources/RFCore/Resources/`，並隨 App 一起打包。

| 元件 | 用途 | 授權 | 是否隨 App 發行 | 全文 |
| --- | --- | --- | --- | --- |
| Lensfun database（commit a3bdffd，`data/db`） | 鏡頭光學校正資料 | CC BY-SA 3.0 | 是（`lensfun/`） | `Lensfun-LICENSE.txt` |
| Real-ESRGAN x2plus（Xintao Wang） | 輸出超解析度 | BSD 3-Clause | 是（Core ML 轉檔） | `RealESRGAN-LICENSE.txt` |
| MediaPipe selfie_multiclass_256x256（Google LLC） | 人物部位分割 | Apache-2.0 | 是（Core ML 轉檔） | `MediaPipe-LICENSE.txt` |
| LaMa（advimman；Core ML 轉檔 john-rocky） | AI 補洞 | Apache-2.0 | 否，使用者要求時才下載 | `LaMa-LICENSE.txt` |

## Lensfun 資料（CC BY-SA 3.0）

- 來源：https://github.com/lensfun/lensfun
- `Sources/RFCore/Resources/lensfun/` 內的 XML 是 Lensfun 資料的副本。若你修改這些 XML 再散布，修改後的資料必須同樣以 CC BY-SA 3.0 釋出並保留出處。
- ShareAlike 只約束資料本身；RenderFilm 程式碼以讀檔方式使用這些資料，程式碼仍採 MIT。

## 模型轉檔

`Scripts/convert-realesrgan.py`、`Scripts/convert-selfie-multiclass.py` 是本專案的轉檔腳本（MIT）；轉出的模型權重仍屬上表原授權。

## 商標

Kodak、Fujifilm、Sony、Canon 等名稱為各自所有者的商標。RenderFilm 是非官方專案，與上述公司無任何關聯，也未獲其認可；底片風格說明中提到的品牌名稱僅作學習與參考用途。
