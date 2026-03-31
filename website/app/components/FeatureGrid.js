"use client";

import { useRef } from "react";
import { motion, useInView } from "framer-motion";
import {
  Monitor,
  Camera,
  Globe,
  Brain,
  Microphone,
  Folders,
} from "@phosphor-icons/react";

const features = [
  {
    icon: Monitor,
    title: "Live screen streaming",
    desc: "Stream your Mac screen to your iPhone in real time. See your IDE, terminal, and browser as you work.",
    colSpan: "md:col-span-3",
  },
  {
    icon: Camera,
    title: "Screenshot to AI",
    desc: "Capture your screen and send it to Claude for vision-powered analysis and code suggestions.",
    colSpan: "md:col-span-2",
  },
  {
    icon: Globe,
    title: "Remote access via relay",
    desc: "Access your Mac from anywhere. No port forwarding or VPN needed — our relay handles everything.",
    colSpan: "md:col-span-2",
  },
  {
    icon: Brain,
    title: "Multi AI engines",
    desc: "Switch between Claude Code, Gemini CLI, Codex, and Aider. Use the best agent for each task.",
    colSpan: "md:col-span-3",
  },
  {
    icon: Microphone,
    title: "Voice to text",
    desc: "Press and hold to dictate prompts. Pick your language and let AI handle the rest.",
    colSpan: "md:col-span-2",
  },
  {
    icon: Folders,
    title: "Workspace management",
    desc: "Create and manage multiple workspaces with different projects, branches, and dev server configs.",
    colSpan: "md:col-span-3",
  },
];

export default function FeatureGrid() {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: "-60px" });

  return (
    <div ref={ref} className="grid grid-cols-1 md:grid-cols-5 gap-3 mt-16">
      {features.map((f, i) => {
        const Icon = f.icon;
        return (
          <motion.div
            key={f.title}
            initial={{ opacity: 0, y: 20 }}
            animate={isInView ? { opacity: 1, y: 0 } : {}}
            transition={{
              duration: 0.5,
              delay: i * 0.08,
              ease: [0.16, 1, 0.3, 1],
            }}
            className={`${f.colSpan} group bg-surface-raised/80 border border-surface-overlay/40 rounded-2xl p-7 transition-all duration-300 hover:border-amber/15 hover:bg-surface-raised`}
          >
            <Icon
              size={28}
              weight="thin"
              className="text-amber mb-4 transition-transform duration-300 group-hover:scale-110"
            />
            <h3 className="text-sm font-semibold text-cream mb-2">
              {f.title}
            </h3>
            <p className="text-xs text-taupe leading-relaxed">{f.desc}</p>
          </motion.div>
        );
      })}
    </div>
  );
}
