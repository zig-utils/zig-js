# TextCodec decoder indexes

`text_codec_indexes.bin` is a compact, deterministic rendering of decoder
tables in Home's pinned WebKit fork at revision
`7ed99c02e50034f869d0db6d487115bb44332fe4`.

The generator verifies the exact SHA-256 digest of each input before writing:

```sh
python3 tools/generate-text-codec-tables.py \
  EncodingTables.cpp TextCodecSingleByte.cpp TextCodecCJK.cpp \
  src/data/text_codec_indexes.bin
```

The generated file is 215,362 bytes with SHA-256
`dfed3a7d3da43b7b003a7241dd6a911d5a4da4c64a00df86aba41e1a15d215ae`.
It contains only decoding indexes; the state machines are implemented in Zig.

The source tables carry this notice:

> Copyright (C) 2020 Apple Inc. All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met:
> 1. Redistributions of source code must retain the above copyright notice,
> this list of conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice,
> this list of conditions and the following disclaimer in the documentation
> and/or other materials provided with the distribution.
>
> THIS SOFTWARE IS PROVIDED BY APPLE INC. “AS IS” AND ANY EXPRESS OR IMPLIED
> WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
> MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
> EVENT SHALL APPLE INC. OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
> INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
> LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
> OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
> LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
> NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
> EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
