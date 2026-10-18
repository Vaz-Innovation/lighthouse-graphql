import { viteBundler } from '@vuepress/bundler-vite'
import { searchPlugin } from '@vuepress/plugin-search'
import { defaultTheme } from '@vuepress/theme-default'
import { defineUserConfig } from 'vuepress'

const repo = 'Vaz-Innovation/lighthouse-graphql'

// The guides in ../docs, grouped as PHP Lighthouse groups its own.
const sidebar = [
  {
    text: 'Getting Started',
    children: ['/docs/motivation.md', '/docs/getting-started.md', '/docs/configuration.md'],
  },
  {
    text: 'The Basics',
    children: [
      '/docs/resolvers.md',
      '/docs/relationships.md',
      '/docs/filtering-and-ordering.md',
      '/docs/mutations.md',
      '/docs/validation.md',
      '/docs/subscriptions.md',
    ],
  },
  { text: 'Security', children: ['/docs/authorization.md', '/docs/security.md'] },
  { text: 'Performance', children: ['/docs/performance.md', '/docs/caching.md'] },
  {
    text: 'Digging Deeper',
    children: ['/docs/custom-directives.md', '/docs/events.md', '/docs/federation.md', '/docs/best-practices.md'],
  },
  { text: 'API Reference', children: ['/docs/directives.md'] },
]

export default defineUserConfig({
  // Served from https://vaz-innovation.github.io/lighthouse-graphql/
  base: '/lighthouse-graphql/',
  lang: 'en-US',
  title: 'Lighthouse GraphQL Rails',
  description: 'SDL-first, directive-driven GraphQL for Ruby on Rails',

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/lighthouse-graphql/favicon.svg' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' }],
    [
      'link',
      {
        rel: 'stylesheet',
        href: 'https://fonts.googleapis.com/css2?family=Miriam+Libre:wght@400;700&family=Nunito:wght@400;600;800&display=swap',
      },
    ],
  ],

  bundler: viteBundler(),

  theme: defaultTheme({
    logo: '/logo.svg',
    repo,
    docsRepo: repo,
    docsBranch: 'main',
    // Pages are copied from the repository's docs/ folder, so their path there is their path here.
    docsDir: '',
    editLinkText: 'Edit this page on GitHub',
    lastUpdated: false,
    contributors: false,
    navbar: [
      { text: 'Docs', link: '/docs/getting-started.md' },
      { text: 'Directives', link: '/docs/directives.md' },
      { text: 'Example app', link: `https://github.com/${repo}/tree/main/example` },
      { text: 'Changelog', link: `https://github.com/${repo}/blob/main/CHANGELOG.md` },
      { text: 'RubyGems', link: 'https://rubygems.org/gems/lighthouse-graphql' },
    ],
    sidebar: { '/docs/': sidebar },
    sidebarDepth: 2,
  }),

  plugins: [searchPlugin({ maxSuggestions: 10 })],
})
