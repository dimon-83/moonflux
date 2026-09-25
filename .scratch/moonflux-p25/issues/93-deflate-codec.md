# 93 — DEFLATE 编解码进 core/codec

**What to build:** feature-matrix 第 20 行的"压缩编解码"内核：RFC 1951 的 inflate（三种
块型 + LZ77 窗口）与 deflate（固定 Huffman + 贪心 LZ77，确定性匹配），外加 RFC 1950
zlib 容器（adler32）与 RFC 1952 gzip 容器（复用既有 IEEE CRC-32）；解压带**炸弹上界**
（超限是结构化拒绝，不是分配）。外部锚点 = Python zlib（三个容器 × 两个压缩级别，
`tools/gen_deflate_vectors.py` 生成金标语料）。

**Status:** done (2026-09-25)

- [x] `core/codec/deflate.mbt`：inflate_raw / deflate_raw / zlib_wrap / gzip_wrap /
      kafka_decompress / kafka_compress_gzip / adler32
- [x] 生成器 + `core/codec_test/deflate_gen.mbt`（8 样本：空、单字节、距离 1 重叠复制、
      超过 258 匹配帽的长串、不可压伪随机、50KB 混合文本、64KiB 零）
- [x] wbtest：Python 输出逐字节读回（zlib6/zlib9/gzip/raw）+ 自往返 + 校验和对照 +
      炸弹拒绝 + 容器损坏拒绝（9 条全绿）
- [x] 执行中修的三个自身 bug：deflate 漏写 BTYPE 块头位；块头写在数据之后；容器
      CRC/ISIZE 误覆盖 deflate 流而非未压缩原文
