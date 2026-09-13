import type { NavigationItem } from "./items";

export function NavigationLink({ item, active, collapsed = false, onNavigate }: {
  item: NavigationItem; active: boolean; collapsed?: boolean; onNavigate?: () => void;
}) {
  const Icon = item.icon;
  // Keep native navigation: persisted workspace state is restored on each page.
  return (
    <a href={item.href} onClick={onNavigate} aria-current={active ? "page" : undefined}
      aria-label={collapsed ? item.label : undefined} title={collapsed ? item.label : undefined}
      className={`group flex min-h-10 items-center rounded-lg text-[13px] transition-colors ${collapsed ? "justify-center px-2" : "gap-3 px-3"} ${active ? "bg-bg-white font-medium text-accent-brand shadow-sm ring-1 ring-border-dim" : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"}`}>
      <Icon size={17} strokeWidth={active ? 2 : 1.7} className="shrink-0" />
      {!collapsed && <span>{item.label}</span>}
      {!collapsed && active && <span className="ml-auto h-1 w-1 rounded-full bg-accent-brand" />}
    </a>
  );
}
