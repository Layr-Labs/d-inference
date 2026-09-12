import { INSTALL_COMMAND } from "@/app/providers/dashboard/fixes";

export const SETUP_STEPS = [
  {
    id: "install",
    title: "Install on your Mac",
    description: "Open Terminal on the Mac you want to connect, then run this command.",
    command: INSTALL_COMMAND,
    note: "If the installer opens System Settings, review and install the device enrollment profile. Then return to Terminal to finish setup.",
  },
  {
    id: "link",
    title: "Link it to your account",
    description: "Run the command, then approve the one-time code in your browser. Use the account where you want to receive this Mac’s earnings.",
    command: "darkbloom login",
    note: "Wait for “Account linked successfully!” in Terminal before continuing.",
  },
  {
    id: "start",
    title: "Choose your models and start",
    description: "The model picker helps you choose what to serve, downloads the models, and starts the provider in the background.",
    command: "darkbloom start",
    note: "The first download can take a while. Keep your Mac connected to power and the internet while it gets ready.",
  },
  {
    id: "check",
    title: "Check your connection",
    description: "Check the provider’s local status, then open your dashboard to see this Mac’s connection, verification, and earnings.",
    command: "darkbloom status",
    note: "If something needs attention, your dashboard explains the next step. A linked Mac may still be downloading models or completing verification.",
  },
] as const;

export const PROVIDER_FAQS = [
  {
    question: "What will run on my Mac?",
    answer: "The provider runs AI models on your Mac’s GPU using Apple Silicon’s unified memory. You choose which models to serve in the Terminal picker. The provider runs as a background service, and darkbloom stop stops it.",
  },
  {
    question: "Why do I need to install a device profile?",
    answer: "Device enrollment lets Darkbloom verify your Mac’s hardware identity and security settings. The installer opens the profile in System Settings for you to review and approve. If you missed that step, run darkbloom enroll to resume it.",
  },
  {
    question: "Can I keep using my Mac?",
    answer: "Yes. Serving models uses memory, GPU time, power, and bandwidth. During setup you choose whether models stay loaded or free memory when idle. Keep the Mac awake while providing; closing a MacBook’s lid can interrupt availability.",
  },
  {
    question: "When will I start earning?",
    answer: "Link your account and get your Mac connected and verified first. Earnings depend on eligible hardware, availability, the models you serve, and network demand. Your dashboard shows recorded earnings; the earnings calculator helps you explore estimates before starting.",
  },
];
