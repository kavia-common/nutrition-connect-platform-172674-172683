# nutrition-connect-platform-172674-172683

This workspace hosts the platform_database container for the Nutrition Connect Platform.

- Default PostgreSQL port: 5002
- Quick connect:
  psql -h localhost -U nc_app -d nutrition_connect -p 5002
- Verify readiness:
  pg_isready -h localhost -p 5002

Database viewer quickstart:
  cd platform_database/db_visualizer
  source postgres.env
  npm install
  npm start
Then open http://localhost:3000 and you should see PostgreSQL listed. If not, ensure startup.sh has run and postgres.env exists with port 5002.

See platform_database/README.md for detailed instructions.