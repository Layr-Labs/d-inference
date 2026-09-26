import Image from "next/image";
import { GridMap } from "./GridMap";

export function LaptopGrid() {
  return (
    <div className="laptop" aria-hidden="true">
      <Image className="laptop-frame" src="/media/laptop-frame.png" alt="" width={1024} height={577} />
      <div className="laptop-map-mask">
        <GridMap compact />
      </div>
    </div>
  );
}
