plugins {
    alias(libs.plugins.bakery)
    kotlin("jvm") version "2.1.20"
}

repositories {
    mavenCentral()
}

bakery { configPath = file("site.yml").absolutePath }

kotlin {
    jvmToolchain(25)
}

dependencies {
    testImplementation(libs.playwright)
    testImplementation("org.junit.jupiter:junit-jupiter:5.12.2")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks {
    named("test", Test::class) {
        useJUnitPlatform()
        environment("BAKE_DIR", file("build/bake").absolutePath)
    }
}

tasks.register("a11yAudit") {
    group = "verification"
    description = "Run accessibility audit on the baked site using Playwright + axe-core"
    dependsOn("bake")
    finalizedBy("test")
}

// ============================================================
// ISO Build Pipeline — Magic Stick
// ============================================================

val magicStickVersion = rootProject.file("VERSION").readText().trim()
val dockerImage = "magic_stick:builder"
val projDir = layout.projectDirectory.asFile.absolutePath
val isoDir = "${projDir}/build"
val isoName = "magic_stick_${magicStickVersion}.iso"

tasks.register<org.gradle.api.tasks.Exec>("dockerBuild") {
    group = "iso"
    description = "Build the Docker builder image (magic_stick:builder) — no-op if image already exists"
    commandLine(
        "bash", "-c",
        "docker image inspect $dockerImage >/dev/null 2>&1 || docker build -t $dockerImage $projDir"
    )
}

tasks.register<org.gradle.api.tasks.Exec>("isoClean") {
    group = "iso"
    description = "Clean ISO build artifacts (keep config)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "bash", "-c", "cd /magic_stick/build && lb clean 2>/dev/null || true")
}

tasks.register<org.gradle.api.tasks.Exec>("isoPurge") {
    group = "iso"
    description = "Purge all ISO build state (config + artifacts)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "bash", "-c", "cd /magic_stick/build && lb clean --purge 2>/dev/null || true")
}

tasks.register<org.gradle.api.tasks.Exec>("isoBuild") {
    group = "iso"
    description = "Build the Magic Stick ISO (lb config + lb build inside Docker)"
    dependsOn("dockerBuild")
    environment("MAGIC_STICK_VERSION", magicStickVersion)
    environment("CLEAN", "false")
    environment("PURGE", "false")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        "-e", "MAGIC_STICK_VERSION=$magicStickVersion",
        "-e", "CLEAN=false",
        "-e", "PURGE=false",
        dockerImage,
        "/magic_stick/scripts/build-inner.sh")
}

tasks.register("isoRebuild") {
    group = "iso"
    description = "Force rebuild the Magic Stick ISO (purge + build)"
    dependsOn("isoPurge")
    finalizedBy("isoBuild")
}

tasks.register<org.gradle.api.tasks.Exec>("isoVerify") {
    group = "iso"
    description = "Verify the built ISO (boot files, bootloader, squashfs)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/verify.sh", "/magic_stick/build/$isoName")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestSmoke") {
    group = "iso"
    description = "Smoke test: boot ISO in QEMU with smoke_test=true and verify all tools run"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/test-boot.sh", "--smoke",
        "/magic_stick/build/$isoName", "300")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestBoot") {
    group = "iso"
    description = "Test ISO boot in QEMU (BIOS + UEFI) inside Docker"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/test-boot.sh", "/magic_stick/build/$isoName", "120")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestSoftware") {
    group = "iso"
    description = "Test installed software inside the ISO squashfs via Docker"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "bash", "/magic_stick/scripts/test-software.sh", "/magic_stick/build/$isoName")
}

tasks.register("isoTest") {
    group = "iso"
    description = "Verify + boot test the built ISO"
    dependsOn("isoVerify", "isoTestBoot")
}

tasks.register("isoPipeline") {
    group = "iso"
    description = "Full pipeline: build ISO + verify + boot test"
    dependsOn("isoBuild")
    finalizedBy("isoTest")
}

tasks.register<org.gradle.api.tasks.Exec>("isoFlash") {
    group = "iso"
    description = "Flash ISO to USB drive — pass device with -Pdevice=/dev/sdX"
    dependsOn("dockerBuild")
    val device = (project.findProperty("device") as? String) ?: "/dev/null"
    commandLine("docker", "run", "--rm", "--privileged",
        "--device", device,
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/flash.sh", device)
    onlyIf { project.hasProperty("device") }
}

// ============================================================
// A/B Partition Test Pipeline
// ============================================================

tasks.register<org.gradle.api.tasks.Exec>("isoTestAB") {
    group = "iso"
    description = "Test A/B partition setup on loopback device inside Docker (privileged)"
    dependsOn("dockerBuild")
    // Runs test-ab-partition.sh inside Docker with all needed perms
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic_stick",
        "--cap-add", "SYS_ADMIN",
        "--device", "/dev/loop-control",
        "--device", "/dev/loop0",
        "--device", "/dev/loop1",
        "--device", "/dev/loop2",
        "--device", "/dev/loop3",
        "--device", "/dev/loop4",
        "--device", "/dev/loop5",
        "--device", "/dev/loop6",
        "--device", "/dev/loop7",
        dockerImage,
        "bash", "-c",
        "chmod +x /magic_stick/scripts/test-ab-partition.sh /magic_stick/scripts/update-system.sh \u0026\u0026 " +
        "/magic_stick/scripts/test-ab-partition.sh create-disk \u0026\u0026 " +
        "/magic_stick/scripts/test-ab-partition.sh setup-ab " +
        (if (file("build/$isoName").exists()) "/magic_stick/build/$isoName" else "") +
        " \u0026\u0026 /magic_stick/scripts/test-ab-partition.sh test"
    )
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestVNC") {
    group = "iso"
    description = "Test ISO GUI boot via QEMU + noVNC inside Docker (ports 5900+6080)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-p", "5900:5900",
        "-p", "6080:6080",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/test-boot.sh", "--vnc",
        "/magic_stick/build/$isoName", "300")
}

tasks.register("isoTestFull") {
    group = "iso"
    description = "Full test suite: verify + boot + A/B partition + software"
    dependsOn("isoVerify", "isoTestSoftware")
    finalizedBy("isoTestBoot")
}

// ============================================================
// Docker Hub CLI image Pipeline
// ============================================================

val dockerhubCredsFile = file("dockerhub-creds.yml")

fun parseDockerhubCreds(): Pair<String, String>? {
    if (!dockerhubCredsFile.exists()) return null
    val lines = dockerhubCredsFile.readLines()
    val user = lines.find { it.contains("username:") }?.substringAfter("username:")?.trim()?.removeSurrounding("\"")?.removeSurrounding("'") ?: ""
    val token = lines.find { it.contains("token:") }?.substringAfter("token:")?.trim()?.removeSurrounding("\"")?.removeSurrounding("'") ?: ""
    return if (user.isNotEmpty() && token.isNotEmpty()) user to token else null
}

tasks.register<org.gradle.api.tasks.Exec>("dockerHubLogin") {
    group = "docker"
    description = "Authenticate to Docker Hub using dockerhub-creds.yml (local only, never CI/CD)"
    val creds = parseDockerhubCreds()
    onlyIf { creds != null }
    commandLine("docker", "login", "-u", creds?.first ?: "", "--password-stdin", "docker.io")
    standardInput = (creds?.second ?: "").byteInputStream()
}

tasks.register<org.gradle.api.tasks.Exec>("dockerBuildCli") {
    group = "docker"
    description = "Build magic-stick-cli Docker image locally"
    val creds = parseDockerhubCreds()
    val repo = if (!creds?.first.isNullOrEmpty()) "${creds?.first}/magic-stick-cli" else "cheroliv/magic-stick-cli"
    commandLine("docker", "buildx", "build",
        "--file", "docker/magic-stick-cli/Dockerfile",
        "--tag", "${repo}:${magicStickVersion}",
        "--tag", "${repo}:latest",
        ".")
}

tasks.register<org.gradle.api.tasks.Exec>("dockerPushCli") {
    group = "docker"
    description = "Build and push magic-stick-cli Docker image to Docker Hub (requires dockerHubLogin)"
    dependsOn("dockerHubLogin")
    val creds = parseDockerhubCreds()
    onlyIf { !creds?.first.isNullOrEmpty() }
    val repo = "${creds?.first}/magic-stick-cli"
    commandLine("docker", "buildx", "build", "--push",
        "--file", "docker/magic-stick-cli/Dockerfile",
        "--tag", "${repo}:${magicStickVersion}",
        "--tag", "${repo}:latest",
        ".")
}
