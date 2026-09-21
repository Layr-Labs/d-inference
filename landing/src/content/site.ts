export const prompts = [
  {
    question: "What is Darkbloom?",
    answer: "Darkbloom is a compute grid that connects idle Macs to real AI demand. Private by construction, attested at the hardware level.",
  },
  {
    question: "How does it work?",
    answer: "A router matches each request to an available Apple Silicon provider that can run it, then returns the result to you.",
  },
  {
    question: "How much can I earn?",
    answer: "Providers earn a base reward for staying online, plus usage earnings whenever their Mac serves a request.",
  },
  {
    question: "Are the prompts private?",
    answer: "Yes. Requests run inside hardware-attested environments, and providers never receive access to your raw conversation or identity.",
  },
] as const;

// Visual route targets only. Provider identity and hardware always come from
// the completed inference request; these coordinates make no data claim.
export const providerOptions = [
  { cell: [53.8529, 32.9188] },
  { cell: [12.3195, 29.0253] },
  { cell: [85.8831, 77.8729] },
  { cell: [32.0302, 70.9704] },
  { cell: [53.8529, 8.318] },
] as const;

const PENDING = "—";

export const stories = [
  {
    slug: "gumbii-life-built-to-serve",
    mac: "Gumbii",
    hardware: PENDING,
    headline: "A Life Built to Serve",
    image: "/media/story-gumbii-poster.jpg",
    video: "/media/story-gumbii.mp4",
    imageAlt: "Gumbii silhouetted by the light from a window",
    stats: [
      { icon: "location", label: "Location", value: "North Carolina, US" },
      { icon: "tokens", label: "Token", value: "26.1M tokens" },
    ],
    summary: "Air Force veteran and father Gumbii built a home compute operation around two priorities: spending time with his family and making his machines useful to others.",
    copy: [
      "Inside a 10-by-10 office near Asheville, North Carolina, Gumbii has assembled a small but formidable computing operation. The hardware reflects a lifetime of learning how to make things work.",
      "An Air Force veteran, Gumbii worked in communications before building online businesses. As AI began reshaping that industry, he sold his portfolio and invested the proceeds in machines of his own. He was initially skeptical that Darkbloom would work. Then his first payment arrived, worth only a fraction of a cent. The amount was irrelevant. It proved that someone, somewhere, had used his hardware.",
      "Gumbii describes himself first as a father. Working at home allows him to spend his finite time with his young daughter while continuing to build, experiment, and learn. The military taught him to solve the problem in front of him; fatherhood taught him why that work matters.",
      "His ambitions extend beyond his household. Gumbii volunteers in his community, supports veterans, and hopes distributed computing can eventually contribute to medical research, particularly cancer research, a cause shaped by losses within his family.",
      "For Gumbii, providing compute is another form of service: something built at home that can still reach beyond it.",
    ],
  },
  {
    slug: "xadens-story",
    mac: "Xaden",
    hardware: PENDING,
    headline: "Freedom, Powered by the Sun",
    image: "/media/story-xaden-poster.jpg",
    video: "/media/story-xaden.mp4",
    imageAlt: "A figure suspended against a cloudy sky",
    stats: [
      { icon: "location", label: "Location", value: "Colorado, US" },
      { icon: "tokens", label: "Token", value: "18.4M tokens" },
    ],
    summary: "From a self-built van in the American West, Xaden combines solar power, distributed systems, and a fiercely independent life to make idle computing power useful to others.",
    copy: [
      "Four and a half years ago, Xaden traded a new Tesla for an empty Sprinter van at a dealership in Indiana. The deal took 30 minutes. Building the van took nine months.",
      "Since then, the van has been his home as he travels across the American West. Solar panels supply its power, Starlink keeps it connected, and a computer inside contributes to Darkbloom from places far beyond the traditional data center.",
      "Before taking to the road, Xaden built a career in software and distributed systems. Those skills helped him design his mobile life, but not without mistakes. He wired equipment incorrectly, bought the wrong appliances, and once welded a wrench to a battery terminal. Learning to recover from those failures gave him something more valuable than a flawless build: the confidence to choose how he wanted to live.",
      "Darkbloom fits a question he had considered for years. Why should powerful computers sit unused when their capacity could be shared with someone who needs it?",
      "His motivation is not primarily financial. It is rooted in access, community, and autonomy. For Xaden, freedom means waking up and choosing where to go, what to work on, and how the tools he owns participate in the wider world.",
    ],
  },
  {
    slug: "sambits-ideas",
    mac: "Sambit",
    hardware: PENDING,
    headline: "The Next Hill to Climb",
    image: "/media/story-sambit-poster.jpg",
    video: "/media/story-sambit.mp4",
    imageAlt: "People gathered on a sunlit coastal overlook",
    stats: [
      { icon: "location", label: "Location", value: "New York, US" },
      { icon: "tokens", label: "Token", value: "11.7M tokens" },
    ],
    summary: "Brooklyn photographer turned creative technologist Sambit approaches AI with the same restless curiosity that first drew him to photography: experimenting, learning, and making ideas real.",
    copy: [
      "Sambit grew up outside New Delhi, India and moved to New York at 19 to study photography. He went on to build a career shooting fashion and portraits, but the images were only part of the attraction. What excited him most was learning how cameras, light, and editing tools could be pushed in unexpected directions.",
      "Eventually, that learning curve began to flatten. AI has given him another hill to climb.",
      "With no formal programming background, Sambit began building small applications through experimentation, often working late into the night to understand why something failed. Those projects helped carry him from photography into creative technology, where he now works between technical and creative teams while continuing his studio practice in Brooklyn.",
      "Before discovering Darkbloom, Sambit had already imagined neighborhood businesses running small inference servers for the people around them. When he found a working version of that idea, he connected his own machines.",
      "“The laptop that I paid for can still do some work and help someone else do their work,” he explained.",
      "That simple possibility captures Sambit’s larger passion: making technology more personal, useful, and open to experimentation. For him, that uncertainty is precisely what makes the work exciting.",
    ],
  },
] as const;

export type StoryStatIcon = (typeof stories)[number]["stats"][number]["icon"];

// Legal is added by SiteNav on the legal routes only, matching the Figma page
// header while keeping the landing and About navigation intentionally spare.
export const primaryLinks = [
  { label: "About", href: "/about" },
  { label: "Docs", href: "https://docs.darkbloom.dev/introduction", external: true },
] as const;

export const socialLinks = [
  { label: "X", href: "https://x.com/darkbloomai" },
  { label: "Github", href: "https://github.com/Layr-Labs/d-inference" },
  { label: "LinkedIn", href: "https://www.linkedin.com/showcase/darkbloom/" },
] as const;
