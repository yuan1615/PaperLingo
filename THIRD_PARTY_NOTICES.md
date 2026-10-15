# Third-party notices

The root [MIT License](LICENSE) covers PaperLingo's own source and documentation. Third-party materials, including files in `packaging/third-party/`, retain their original licenses. Model weights and runtime binaries are not committed to this repository.

## OmniVoice

- Code: <https://github.com/k2-fsa/OmniVoice>, version 0.2.1, Apache-2.0.
- Model: <https://huggingface.co/k2-fsa/OmniVoice>.
- v0.1.0 snapshot: `c5fdb5ccb189668d56333f77ba2629f4cd7535f4`.
- Authors: Han Zhu, Lingxuan Ye, Wei Kang, Zengwei Yao, Liyong Guo, Fangjun Kuang, Zhifeng Han, Weiji Zhuang, Long Lin, and Daniel Povey.
- Weights use the CC-BY-NC license stated in the included model card. The source MIT license does not authorize commercial use of these weights.
- Included references: [model card](packaging/third-party/OmniVoice-MODEL-CARD.md), [code license](packaging/third-party/OmniVoice-CODE-LICENSE.txt), [CC-BY-NC 4.0 text](packaging/third-party/CC-BY-NC-4.0.html).

## TranslateGemma / Gemma

Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms.

- Model: Google TranslateGemma 4B, distributed by Ollama as `translategemma:4b`, Q4_K_M.
- Verified v0.1.0 manifest: `c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`.
- Terms: <https://ai.google.dev/gemma/terms>.
- Prohibited use policy: <https://ai.google.dev/gemma/prohibited_use_policy>.
- All model use must follow the applicable Gemma terms and use restrictions, including Section 3.2. Upstream model tags can change; the recorded digest identifies the tested build, not every future download of the tag.
- Copies of the packaged terms, retrieved current terms and prohibited use policy are in [packaging/third-party/](packaging/third-party/).

## Higgs Audio V2 tokenizer

The OmniVoice snapshot contains Boson AI's Higgs Audio V2 tokenizer. Its community license and the upstream README are preserved as [Higgs-Audio-Tokenizer-LICENSE.txt](packaging/third-party/Higgs-Audio-Tokenizer-LICENSE.txt) and [Higgs-Audio-Tokenizer-README.md](packaging/third-party/Higgs-Audio-Tokenizer-README.md), including referenced upstream model terms.

## Ollama, Python and runtime dependencies

- Ollama 0.40.4: MIT; [license copy](packaging/third-party/Ollama-LICENSE.txt).
- CPython 3.11.17 and Python dependencies retain their upstream licenses in the bundled standard library and `.dist-info` directories.
- Dependency versions are recorded in [engine/requirements.txt](engine/requirements.txt). Building an offline app preserves the Python and Ollama license files alongside their binaries.

The offline distribution includes [Notice](packaging/third-party/Notice). Model weights are bundled without modification. Before redistributing a model-containing build, review the included third-party terms; the complete v0.1.0 model bundle is intended for personal, noncommercial learning.
