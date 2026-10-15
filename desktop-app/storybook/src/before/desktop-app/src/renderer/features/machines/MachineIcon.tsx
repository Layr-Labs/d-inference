import { Laptop, Monitor } from 'lucide-react';

export function MachineIcon({
  name,
  size,
  strokeWidth,
}: {
  name: string;
  size: number;
  strokeWidth?: number;
}) {
  const Icon = name.includes('Book') ? Laptop : Monitor;
  return <Icon size={size} strokeWidth={strokeWidth} />;
}
