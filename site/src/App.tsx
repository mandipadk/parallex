import { MotionConfig } from "motion/react"
import { Features } from "@/components/site/features"
import { FinalCta } from "@/components/site/final-cta"
import { Footer } from "@/components/site/footer"
import { Hero } from "@/components/site/hero"
import { HowItWorks } from "@/components/site/how-it-works"
import { Nav } from "@/components/site/nav"

export default function App() {
  return (
    <MotionConfig reducedMotion="user">
      <Nav />
      <main>
        <Hero />
        <Features />
        <HowItWorks />
        <FinalCta />
      </main>
      <Footer />
    </MotionConfig>
  )
}
