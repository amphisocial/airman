// pm2 start ecosystem.config.cjs
module.exports = {
  apps: [
    {
      name: 'sortie',
      cwd: __dirname + '/server',
      script: 'src/index.js',
      exec_mode: 'fork',
      instances: 1,
      autorestart: true,
      max_memory_restart: '250M',
      env: {
        NODE_ENV: 'production',
        PORT: '4020',
      },
      out_file: __dirname + '/logs/sortie.out.log',
      error_file: __dirname + '/logs/sortie.err.log',
      merge_logs: true,
      time: true,
    },
  ],
};
