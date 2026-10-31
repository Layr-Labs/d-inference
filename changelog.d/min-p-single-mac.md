### A request's `min_p` now applies on one Mac too

- A request's `min_p` now applies on one Mac too, as it already did on a cluster pair: tokens less likely than `min_p` times the most likely token are dropped before sampling (values above 1 count as 1). Requests without `min_p`, or with 0, are unchanged.
