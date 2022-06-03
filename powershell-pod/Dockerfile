FROM mcr.microsoft.com/windows/servercore:ltsc2019

WORKDIR "C:\\"

# Install Chocolatey
RUN powershell -Command Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Install Apache Bench
RUN choco install -y apache-httpd
RUN setx path "%path%;C:\Users\ContainerAdministrator\AppData\Roaming\Apache24\bin"
