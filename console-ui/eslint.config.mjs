import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import security from "eslint-plugin-security";
import sonarjs from "eslint-plugin-sonarjs";
import promise from "eslint-plugin-promise";

const eslintConfig = defineConfig([
  ...nextVitals,
  globalIgnores([".next/**", "out/**", "build/**", "next-env.d.ts"]),
  security.configs.recommended,
  sonarjs.configs.recommended,
  promise.configs["flat/recommended"],
  {
    rules: {
      // React 19.2 adds this rule but our init-in-useEffect patterns are fine
      // (theme init from localStorage, settings load, etc.)
      "react-hooks/set-state-in-effect": "off",
      "@next/next/no-img-element": "off",

      // Security
      "no-eval": "error",
      "no-implied-eval": "error",
      "no-new-func": "error",

      // Promise handling
      "promise/catch-or-return": "warn",
      "promise/no-return-wrap": "error",
      "promise/always-return": "warn",

      // Sonarjs — tune down noisy rules to warnings
      "sonarjs/cognitive-complexity": "warn",
      "sonarjs/no-nested-conditional": "warn",
      "sonarjs/no-nested-functions": "warn",
      "sonarjs/no-nested-template-literals": "warn",
      "sonarjs/pseudo-random": "warn",
      "sonarjs/use-type-alias": "warn",
      "sonarjs/no-duplicate-string": "warn",
      "sonarjs/no-redundant-boolean": "warn",

      // Production hygiene
      "no-debugger": "error",
      "no-unsafe-finally": "error",
    },
  },
]);

export default eslintConfig;
