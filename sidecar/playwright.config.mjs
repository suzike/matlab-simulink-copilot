import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './test-ui',
  outputDir: '../_verify/playwright-results',
  reporter: [['list'], ['html', { outputFolder: '../_verify/playwright-report', open: 'never' }]],
  use: {
    browserName: 'chromium',
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1100, height: 1000 } } },
    { name: 'narrow', use: { viewport: { width: 520, height: 900 } } },
  ],
});
