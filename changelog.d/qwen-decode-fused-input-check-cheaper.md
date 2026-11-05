### Qwen 3.5-family decode spends less host time per token

- Each Qwen decode step checked that some of its weights were still frozen by walking every layer's whole set of weights; it now looks only at the weights it needs. This applies to one Mac and to pairs. On a Qwen 3.8 27B pair the check was about 6 % of the host's time per token. The output is unchanged.
