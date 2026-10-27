# Vektor plugin SDK for Node.js

The Node.js half of the Vektor plugin SDK: see [`sdk/README.md`](../README.md) in the plugins repository for what it offers,
its version and the Vektor it needs, and `templates/node` for a plugin built on it. No runtime dependencies; Node.js 18 or later. The guide is [`docs/sdk-node.md`](../../docs/sdk-node.md); the layouts (`src/layouts/`) are
described in [`docs/sdk-layouts.md`](../../docs/sdk-layouts.md).

    const { Plugin, blocks: b } = require('./vektor-sdk');
    const plugin = new Plugin();
    plugin.command('hello', (target) => `Hello! You chose ${(target.items || []).length} item(s).`);
    plugin.start();
