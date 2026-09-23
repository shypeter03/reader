---
license: apache-2.0
language:
- en
- zh
- ja
- ko
- fr
- de
- es
tags:
- speech
- tts
- mlx
- qwen3
library_name: mlx
base_model: Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice
---

# Qwen3 TTS 12Hz 0.6B CustomVoice — MLX 4-bit

MLX 4-bit quantized conversion of [Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice) for Apple Silicon inference.

## Usage

Used by [qwen3-asr-swift](https://github.com/AufklarerStudios/qwen3-asr-swift) `Qwen3TTS` module:

```swift
let model = try await Qwen3TTSModel.fromPretrained(
    modelId: TTSModelVariant.customVoice.rawValue
)
let audio = try model.synthesize("Hello!", speaker: "Chelsie")
```

```bash
audio speak "Hello!" --model custom-voice --speaker Chelsie -o output.wav
```

## Model Details

- **Architecture**: Qwen3-TTS (Talker transformer + Code Predictor + Mimi speech tokenizer decoder)
- **Parameters**: 0.6B
- **Quantization**: 4-bit (MLX, talker only)
- **Size**: ~964 MB
- **Sample rate**: 24 kHz
- **Codec rate**: 12.5 Hz
- **Voices**: 9 preset voices + instruction-based style control
