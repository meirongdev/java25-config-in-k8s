# Stage 1: Build
FROM eclipse-temurin:25-jdk AS build
WORKDIR /app
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN ./mvnw dependency:go-offline -q
COPY src ./src
RUN ./mvnw package -DskipTests -q

# Stage 2: Runtime（Java 25 为非LTS版本，eclipse-temurin 只发布 JDK 镜像，无独立 JRE 镜像）
FROM eclipse-temurin:25-jdk
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080

# JAVA_TOOL_OPTIONS 由 K8s Deployment env 注入，JVM 自动读取
ENTRYPOINT ["java", "-jar", "app.jar"]
