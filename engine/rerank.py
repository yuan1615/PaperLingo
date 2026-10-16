"""Pinned local Qwen3 reranking. No generation, downloads or remote requests."""
from pathlib import Path
import math


class LocalReranker:
    def __init__(self, path):
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        self.torch = torch
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.tokenizer = AutoTokenizer.from_pretrained(path, padding_side="left", local_files_only=True)
        self.model = AutoModelForCausalLM.from_pretrained(
            path, local_files_only=True, dtype=torch.float32,
            attn_implementation="eager").to(self.device).eval()
        self.no = self.tokenizer.convert_tokens_to_ids("no")
        self.yes = self.tokenizer.convert_tokens_to_ids("yes")
        self.prefix = self.tokenizer.encode(
            '<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct provided. Note that the answer can only be "yes" or "no".<|im_end|>\n<|im_start|>user\n', add_special_tokens=False)
        self.suffix = self.tokenizer.encode('<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n', add_special_tokens=False)

    def score(self, query, documents):
        torch = self.torch
        result = []
        for start in range(0, len(documents)):
            texts = [f"<Instruct>: Retrieve scientific papers whose overview and personal notes address the research question. A passing mention alone is insufficient.\n<Query>: {query}\n<Document>: {document}"
                     for document in documents[start:start+1]]
            encoded = self.tokenizer(texts, padding=False, truncation=True,
                                     max_length=4096-len(self.prefix)-len(self.suffix), add_special_tokens=False)
            tokens = [{"input_ids": self.prefix+ids+self.suffix,
                       "attention_mask": [1]*(len(self.prefix)+len(ids)+len(self.suffix))}
                      for ids in encoded["input_ids"]]
            inputs = self.tokenizer.pad(tokens, padding=True, return_tensors="pt").to(self.device)
            with torch.inference_mode():
                logits = self.model(**inputs, use_cache=False, logits_to_keep=1).logits[:, -1, :]
                scores = torch.softmax(torch.stack([logits[:, self.no], logits[:, self.yes]], dim=1).float(), dim=1)[:, 1].cpu().tolist()
            if not all(math.isfinite(score) for score in scores):
                raise RuntimeError("Reranker returned non-finite scores")
            result.extend(scores)
        return result
