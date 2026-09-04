import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import StatsPage from "./page";

vi.mock("@/components/TopBar", () => ({ TopBar: () => <div>Console navigation</div> }));
const provider = {
  id:"node-1",chip:"Apple M4 Pro",chip_family:"M4",chip_tier:"Pro",machine_model:"Mac mini",memory_gb:32,gpu_cores:20,cpu_cores:{total:12,performance:8,efficiency:4},memory_bandwidth_gbs:273,status:"online",trust_level:"hardware",attested:true,decode_tps:10,requests_served:10,tokens_generated:30,
};
const stats = {
  total_requests:10,total_prompt_tokens:20,total_completion_tokens:10,total_tokens:30,
  last_24h_requests:4,last_24h_total_tokens:12,avg_tokens_per_request:3,active_providers:1,total_gpu_cores:20,
  total_cpu_cores:12,total_memory_gb:32,total_bandwidth_gbs:273,network_capacity_tps:10,providers:[provider],models:[],provider_locations:[],provider_regions:[],request_locations:[],request_regions:[],time_series:[],
};
beforeEach(() => {
  vi.stubGlobal("fetch",vi.fn(async(input:RequestInfo|URL)=>{
    if(String(input).startsWith("/api/stats")) return new Response(JSON.stringify(stats),{status:200,headers:{"Content-Type":"application/json","X-Stats-Snapshot-At":new Date().toISOString()}});
    return new Response(null,{status:404});
  }));
});
afterEach(()=>vi.unstubAllGlobals());

describe("Continuous network overview",()=>{
  it("presents geography, activity, model capacity and silicon together without navigation tabs",async()=>{
    render(<StatsPage/>);
    expect(await screen.findByText("Macs online")).toBeInTheDocument();
    expect(screen.getByText("Refreshes every 30 seconds")).toBeInTheDocument();
    expect(screen.queryByRole("tablist")).not.toBeInTheDocument();
    for(const name of ["Network geography","Activity over time","Model capacity","The silicon behind the network"]){
      expect(screen.getByRole("heading",{name})).toBeInTheDocument();
    }
    expect(screen.queryByRole("searchbox",{name:"Search provider fleet"})).not.toBeInTheDocument();
  });
  it("opens the provider directory in place while retaining the graphs",async()=>{
    render(<StatsPage/>);
    const summary=await screen.findByText(/Explore all 1 providers/);
    fireEvent.click(summary);
    expect(await screen.findByRole("searchbox",{name:"Search provider fleet"})).toBeInTheDocument();
    expect(screen.getByRole("heading",{name:"Model capacity"})).toBeInTheDocument();
    expect(screen.getByRole("heading",{name:"Network geography"})).toBeInTheDocument();
  });
});
