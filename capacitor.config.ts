import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.innotechge.yumipay',
  appName: 'Yumi Pay',
  webDir: 'dist/client',
  server: {
    androidScheme: 'https'
  }
};

export default config;
