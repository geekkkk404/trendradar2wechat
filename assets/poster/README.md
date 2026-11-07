# P-61 海报配置卡装饰条（C 款，站主 2026-11-07 选定）

- `c_header.html` / `c_footer.html`：装饰条设计源（720px 逻辑宽，trcfg slate 设计体系）。
  重烤方式：无头浏览器 2x 截图（1440×300 / 1440×240），再 `PIL optimize=True` 压缩。
- `c_header_opt.png` / `c_footer_opt.png`：烤制产物，**base64 内嵌于 install-trendradar.sh**
  （`POSTER_HEADER_B64` / `POSTER_FOOTER_B64`）。改设计 = 改 HTML → 重烤 → 重内嵌。
- 时间戳由管家运行时画在头条右下（HTML 中留白区）；中段（QR+摘要卡）由管家 Pillow 实时合成。
