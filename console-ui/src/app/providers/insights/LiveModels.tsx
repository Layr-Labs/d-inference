"use client";

import { useEffect, useState } from "react";
import { Activity, Pause, Play } from "lucide-react";
import { ModelMakerMark } from "../../stats/ModelMakerMark";
import { shortModelName } from "@/lib/format";
import type { MyProvider } from "../types";
import { modelActivity } from "./activity";
import { compact } from "./types";
import styles from "./insights.module.css";

function activityLabel(stale: boolean, running: number) {
  if (stale) return "Delayed";
  return running > 0 ? `${running} running` : "Ready";
}

export function LiveModels({ providers, heartbeatSeconds, pollFailed, lastUpdatedAt }: {
  providers: MyProvider[]; heartbeatSeconds: number; pollFailed: boolean; lastUpdatedAt: number | null;
}) {
  const [now, setNow] = useState(() => Date.now());
  const [motion, setMotion] = useState(true);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 5000); return () => clearInterval(timer); }, []);
  const stale = pollFailed || lastUpdatedAt === null || now - lastUpdatedAt > 35_000;
  const activity = modelActivity(providers, now, heartbeatSeconds);
  const running = activity.models.reduce((sum, row) => sum + row.running, 0);
  const noFreshReports = activity.models.length === 0 && activity.unknown > 0;
  return (
    <section className={styles.live} aria-labelledby="live-models-title" data-animate={motion && !stale}>
      <div className={styles.sectionHead}>
        <div><div className={styles.eyeline}><Activity size={16} /><span>{stale ? "Activity delayed" : "Live fleet"}</span></div><h2 id="live-models-title">Models at work</h2></div>
        <button type="button" onClick={() => setMotion(!motion)} className={styles.motionButton} aria-pressed={!motion} aria-label={motion ? "Pause activity animation" : "Play activity animation"}>{motion ? <Pause size={14} /> : <Play size={14} />}<span>{motion ? "Pause motion" : "Resume motion"}</span></button>
      </div>
      <div className={styles.liveSummary}><strong>{stale || noFreshReports ? "—" : compact(running)}</strong><span>observed requests running<br /><span className="text-text-tertiary">{activity.models.length} models reporting across your fleet</span></span></div>
      <div className={styles.lanes}>
        {activity.models.map(row => (
          <details className={styles.lane} key={row.model}>
            <summary>
              <span className={styles.modelName}><ModelMakerMark modelId={row.model} compact /><span title={row.model}>{shortModelName(row.model)}<small>{row.machines.length} {row.machines.length === 1 ? "Mac" : "Macs"} · {row.waiting} waiting</small></span></span>
              <span className={styles.activityCells} aria-hidden="true">{Array.from({ length: 24 }, (_, index) => <i key={index} data-active={!stale && index < row.running} style={{ animationDelay: `${index * 65}ms` }} />)}</span>
              <span className={styles.running}>{activityLabel(stale, row.running)}</span>
            </summary>
            <div className={styles.machineDetail}>{row.machines.map(id => { const provider = providers.find(p => p.id === id); return <span key={id}>{provider?.hardware.chip_name || "Mac"} <small>{id.slice(0, 8)}</small></span>; })}</div>
          </details>
        ))}
        {activity.models.length === 0 && <p className={styles.empty}>{activity.unknown ? "Waiting for fresh model activity from your Macs." : "No models are currently loaded. Activity appears when your Macs report a loaded model."}</p>}
      </div>
      <p className={styles.note}>{stale ? "Refresh delayed. Last reported counts are hidden until a fresh snapshot arrives." : "Updates every 15 seconds. Each lit cell represents a running request, up to 24 per model."}{activity.unknown > 0 && ` ${activity.unknown} online ${activity.unknown === 1 ? "Mac has" : "Macs have"} no fresh capacity report.`} No request content is shown.</p>
    </section>
  );
}
