#!/bin/sh
set -e

echo "========================================"
echo "Current Directory"
echo "========================================"
pwd

echo "========================================"
echo "Files in /app"
echo "========================================"
find /app -maxdepth 3

echo "========================================"
echo "packages.yml"
echo "========================================"
cat /app/packages.yml

echo "========================================"
echo "Installed Python Packages"
echo "========================================"
pip freeze | grep dbt

echo "========================================"
echo "Python Site Packages"
echo "========================================"
python -c "
import site
for p in site.getsitepackages():
    print(p)
"

echo "========================================"
echo "Athena Adapter Location"
echo "========================================"
python -c "
import dbt.adapters.athena
print(dbt.adapters.athena.__file__)
"

echo "========================================"
echo "All dbt_project.yml Files"
echo "========================================"
find / -name dbt_project.yml 2>/dev/null

echo "========================================"
echo "All dbt_athena Directories"
echo "========================================"
find / -type d -name "dbt_athena" 2>/dev/null

echo "========================================"
echo "dbt_packages Directory"
echo "========================================"
find /app/dbt_packages 2>/dev/null || echo "No dbt_packages directory"

echo "========================================"
echo "Running dbt Debug"
echo "========================================"
dbt debug

echo "========================================"
echo "Running dbt Parse"
echo "========================================"
dbt parse --debug

echo "========================================"
echo "Running dbt Models"
echo "========================================"
dbt run