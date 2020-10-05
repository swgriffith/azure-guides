FROM mcr.microsoft.com/dotnet/framework/runtime:4.8-windowsservercore-ltsc2019

WORKDIR app

COPY app/* ./

ENTRYPOINT ["ContainerMemoryTester.exe"]
