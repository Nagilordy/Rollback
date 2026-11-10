import { defineConfig } from 'vitepress'

const repo = 'https://github.com/Nagilordy/Rollback'

export default defineConfig({
  title: 'Rollback',
  description: 'Your Jellyfin library, the way a console would show it. A couch-first app for Jellyfin on Linux and Windows.',
  base: '/Rollback/',
  cleanUrls: true,
  appearance: 'force-dark',
  lastUpdated: false,
  head: [
    ['link', { rel: 'icon', href: '/Rollback/icon.svg' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'stylesheet', href: 'https://fonts.googleapis.com/css2?family=Hanken+Grotesk:wght@400;500;600;700&family=Sora:wght@600;700&display=swap' }],
    ['meta', { property: 'og:title', content: 'Rollback' }],
    ['meta', { property: 'og:description', content: 'Your Jellyfin library, the way a console would show it.' }],
  ],
  themeConfig: {
    logo: '/mark.svg',
    siteTitle: 'Rollback',
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Download', link: '/download' },
      { text: "What's new", link: '/whats-new' },
      { text: 'GitHub', link: repo },
    ],
    sidebar: {
      '/guide/': [
        {
          text: 'Guide',
          items: [
            { text: 'Set up from scratch', link: '/guide/setup' },
            { text: 'Getting started', link: '/guide/getting-started' },
            { text: 'Controller and keyboard', link: '/guide/controls' },
            { text: 'Watch parties', link: '/guide/watch-party' },
            { text: 'Playback and quality', link: '/guide/playback' },
            { text: 'Troubleshooting', link: '/guide/troubleshooting' },
          ],
        },
      ],
    },
    search: { provider: 'local' },
    outline: { level: [2, 3], label: 'On this page' },
    footer: {
      message: 'A hobby project for Jellyfin · Linux and Windows',
      copyright: '© 2026 Nagi Lordy',
    },
    docFooter: { prev: 'Previous', next: 'Next' },
  },
})
