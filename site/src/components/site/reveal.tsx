import { motion, type HTMLMotionProps } from "motion/react"
import { EASE, riseIn } from "@/lib/site"

type RevealProps = HTMLMotionProps<"div"> & { delay?: number }

/** Scroll reveal: blur + 16px rise + fade, once, as it enters the viewport. */
export function Reveal({ delay = 0, children, ...props }: RevealProps) {
  return (
    <motion.div
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, margin: "0px 0px -12% 0px" }}
      variants={riseIn}
      transition={{ duration: 0.6, ease: EASE, delay }}
      {...props}
    >
      {children}
    </motion.div>
  )
}

/** Stagger container: children using `riseIn` variants animate in sequence. */
export function RevealGroup({
  stagger = 0.08,
  children,
  ...props
}: HTMLMotionProps<"div"> & { stagger?: number }) {
  return (
    <motion.div
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, margin: "0px 0px -12% 0px" }}
      transition={{ staggerChildren: stagger }}
      {...props}
    >
      {children}
    </motion.div>
  )
}

export function RevealItem({ children, ...props }: HTMLMotionProps<"div">) {
  return (
    <motion.div variants={riseIn} transition={{ duration: 0.6, ease: EASE }} {...props}>
      {children}
    </motion.div>
  )
}
