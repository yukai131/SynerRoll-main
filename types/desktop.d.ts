export {}
declare global {
  interface Window {
    synerroll?: {
      platform: string
      versions: { electron: string; chrome: string; node: string }
      openLocation(location: 'data' | 'logs' | 'settings'): Promise<void>
    }
  }
}
