"use client";

import { useRef } from "react";
import { motion, useInView } from "framer-motion";

export default function ScrollReveal({
  children,
  delay = 0,
  className = "",
}) {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: "-80px" });

  return (
    <motion.div
      ref={ref}
      initial={{ y: 16 }}
      animate={isInView ? { y: 0 } : { y: 16 }}
      transition={{
        duration: 0.6,
        delay,
        ease: [0.16, 1, 0.3, 1],
      }}
      className={className}
    >
      {children}
    </motion.div>
  );
}
