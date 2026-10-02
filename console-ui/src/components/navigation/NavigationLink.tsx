import type { NavigationItem } from "./items";

export function NavigationLink({ item, active, collapsed = false, onNavigate }: {
  item: NavigationItem; active: boolean; collapsed?: boolean; onNavigate?: () => void;
}) {
  const Icon = item.icon;
  // Keep native navigation: persisted workspace state is restored on each page.
  return (
    <a href={item.href} onClick={onNavigate} aria-current={active ? "page" : undefined}
      aria-label={collapsed ? item.label : undefined} title={collapsed ? item.label : undefined}
      className={`console-navigation-link group flex min-h-10 items-center rounded-lg text-[13px] transition-colors ${collapsed ? "justify-center px-2" : "gap-3 px-3"} ${active ? "font-medium text-text-primary" : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"}`}>
      <Icon size={17} strokeWidth={active ? 2 : 1.7} className="shrink-0" />
      {!collapsed && <span>{item.label}</span>}
    </a>
  );
}
