const layers = Array.from({ length: 6 }, () => [] as string[]);

for (let ring = 0; ring < 80; ring++) {
  const u = (ring / 80) * Math.PI * 2;
  const radius = 132 + 16 * Math.cos(u * 3);
  for (let point = 0; point < 24; point++) {
    const v = (point / 24) * Math.PI * 2;
    const x = (radius + 66 * Math.cos(v)) * Math.cos(u);
    const y = (radius + 66 * Math.cos(v)) * Math.sin(u);
    const z = 66 * Math.sin(v);
    const tiltY = y * 0.58 - z * 0.82;
    const depth = y * 0.82 + z * 0.58;
    const projectedX = 300 + x * 0.94 - tiltY * 0.34;
    const projectedY = 245 + x * 0.34 + tiltY * 0.94;
    const layer = Math.min(5, Math.max(0, Math.floor((depth + 190) / 65)));
    layers[layer].push(
      `M${projectedX.toFixed(1)} ${projectedY.toFixed(1)}h.01`,
    );
  }
}

export function NetworkArt() {
  return (
    <svg
      className="network-art"
      viewBox="0 0 600 490"
      fill="none"
      aria-hidden="true"
    >
      {layers.map((points, index) => (
        <path
          key={index}
          d={points.join("")}
          stroke="#95bfff"
          strokeWidth={1.7 + index * 0.26}
          strokeLinecap="round"
          opacity={0.35 + index * 0.13}
        />
      ))}
    </svg>
  );
}
