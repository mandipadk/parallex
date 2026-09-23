export const DOWNLOAD_URL =
  "https://github.com/mandipadk/parallex/releases/latest/download/Parallex.dmg"
export const REPO_URL = "https://github.com/mandipadk/parallex"

/** Shared motion curve and the Spell-style entrance (blur + rise + fade). */
export const EASE = [0.22, 1, 0.36, 1] as const

export const riseIn = {
  hidden: { opacity: 0, y: 16, filter: "blur(10px)" },
  visible: { opacity: 1, y: 0, filter: "blur(0px)" },
}
