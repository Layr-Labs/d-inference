export function NetworkArt() {
  return (
    <div
      className="network-art"
      aria-label="Illustration of a distributed network of verified compute nodes"
      role="img"
    >
      <div className="art-grid" />
      <span className="art-coordinate coordinate-top">
        DISTRIBUTED BY DESIGN
      </span>
      <svg
        className="network-svg"
        viewBox="0 0 600 600"
        fill="none"
        aria-hidden="true"
      >
        <defs>
          <linearGradient
            id="top"
            x1="140"
            y1="80"
            x2="400"
            y2="380"
            gradientUnits="userSpaceOnUse"
          >
            <stop stopColor="#95BFFF" />
            <stop offset="1" stopColor="#4f62ba" />
          </linearGradient>
          <linearGradient
            id="front"
            x1="200"
            y1="250"
            x2="330"
            y2="420"
            gradientUnits="userSpaceOnUse"
          >
            <stop stopColor="#3c3497" />
            <stop offset="1" stopColor="#1A0C6D" />
          </linearGradient>
          <linearGradient
            id="side"
            x1="300"
            y1="300"
            x2="420"
            y2="400"
            gradientUnits="userSpaceOnUse"
          >
            <stop stopColor="#716fd0" />
            <stop offset="1" stopColor="#302477" />
          </linearGradient>
          <filter id="shadow" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="15" />
          </filter>
          <g id="node">
            <path
              d="m0-39 68 39L0 39-68 0Z"
              fill="url(#top)"
              stroke="#b4d1ff"
              strokeWidth=".7"
            />
            <path d="m-68 0 68 39v27l-68-39Z" fill="#21156d" />
            <path d="m0 39 68-39v27L0 66Z" fill="#544fa2" />
            <path d="m-54 19 30 17m-30-12 30 17" stroke="#655fb7" />
            <circle cx="47" cy="30" r="2.5" fill="#b6dcff" />
          </g>
        </defs>
        <ellipse
          cx="304"
          cy="471"
          rx="125"
          ry="34"
          fill="#352871"
          opacity=".17"
          filter="url(#shadow)"
        />
        <g stroke="#7368a8" strokeWidth="1" opacity=".42">
          <path
            d="m97 286 205-119 205 119v114L302 519 97 400Z"
            strokeDasharray="4 6"
          />
          <path d="m97 286 205 119 205-119M302 405v114M97 400l205-119 205 119M302 167v114" />
          <path d="m163 174 139-80 139 80M164 467l138 80 139-80" />
        </g>
        <use href="#node" transform="translate(112 251) scale(.64)" />
        <use href="#node" transform="translate(485 256) scale(.64)" />
        <use href="#node" transform="translate(109 418) scale(.55)" />
        <use href="#node" transform="translate(485 425) scale(.55)" />
        <g className="floating-core">
          {[84, 56, 28, 0].map((y) => (
            <g key={y} transform={`translate(0 ${y})`}>
              <path
                d="m300 154 116 67-116 68-116-68Z"
                fill="url(#top)"
                stroke="#afc8ff"
                strokeWidth=".8"
              />
              <path d="m184 221 116 68v22l-116-67Z" fill="url(#front)" />
              <path d="m300 289 116-68v22l-116 68Z" fill="url(#side)" />
              <path
                d="m199 238 37 22m-37-16 37 22"
                stroke="#8b8bd3"
                strokeWidth="1"
                opacity=".65"
              />
              <circle cx="395" cy="244" r="2" fill="#c4ddff" />
            </g>
          ))}
          <path
            d="m300 167 91 53-91 53-91-53Z"
            stroke="#e2ecff"
            strokeWidth=".7"
            opacity=".6"
          />
          <g transform="translate(288 200) skewY(30) scale(.18)" fill="#1a0c6d">
            <path d="M126 126H95V190H63V0H0V253H190V190H126Z" />
            <path d="M221 0H190V63H221Z" />
            <path d="M158 0H96V32H126V126H190V63H158Z" />
          </g>
        </g>
        <g fill="#1a0c6d">
          <circle cx="302" cy="94" r="4" />
          <circle cx="302" cy="547" r="4" />
          <circle cx="97" cy="286" r="3" />
          <circle cx="507" cy="286" r="3" />
        </g>
        <g stroke="#8074a8" strokeWidth=".8">
          <path d="M302 80V55h66M302 560v12h-74" />
          <path d="M76 255H45v-52m461 240h44v-29" />
        </g>
      </svg>
      <span className="art-tag tag-top">
        <span className="status-dot" />
        Hardware verified
      </span>
      <span className="art-tag tag-bottom">Encrypted in transit</span>
      <div className="art-caption">
        <span>APPLE SILICON. SHARED POTENTIAL.</span>
        <span>FIG. 001</span>
      </div>
    </div>
  );
}
