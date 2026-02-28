#!/usr/bin/env node

const [cmd = 'install'] = process.argv.slice(2);

switch (cmd) {
  case 'install':
    await import('../scripts/install.mjs');
    break;
  case 'uninstall':
    await import('../scripts/uninstall.mjs');
    break;
  case 'status':
    await import('../scripts/status.mjs');
    break;
  case 'fix':
    await import('../scripts/fix.mjs');
    break;
  default:
    console.error(`Unknown command: ${cmd}\nUsage: dotfiles [install|uninstall|status|fix]`);
    process.exit(1);
}
