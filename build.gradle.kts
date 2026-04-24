plugins {
    alias(libs.plugins.bakery)
    kotlin("jvm") version "2.1.20"
}

repositories {
    mavenCentral()
}

bakery { configPath = file("site.yml").absolutePath }

kotlin {
    jvmToolchain(17)
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

val magicStickVersion = "0.1.0"
val dockerImage = "magic_stick:builder"
val projDir = layout.projectDirectory.asFile.absolutePath
val isoDir = "${projDir}/build"
val isoName = "magic_stick_${magicStickVersion}.iso"

tasks.register<org.gradle.api.tasks.Exec>("dockerBuild") {
    group = "iso"
    description = "Build the Docker builder image (magic_stick:builder)"
    commandLine("docker", "build", "-t", dockerImage, projDir)
}

tasks.register<org.gradle.api.tasks.Exec>("isoClean") {
    group = "iso"
    description = "Clean ISO build artifacts (keep config)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "bash", "-c", "cd /magic_stick/build && lb clean 2>/dev/null || true")
}

tasks.register<org.gradle.api.tasks.Exec>("isoPurge") {
    group = "iso"
    description = "Purge all ISO build state (config + artifacts)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm",
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
    environment("PURGE", "true")
    commandLine("docker", "run", "--rm",
        "-v", "$projDir:/magic_stick",
        "-e", "MAGIC_STICK_VERSION=$magicStickVersion",
        "-e", "CLEAN=false",
        "-e", "PURGE=true",
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
    commandLine("docker", "run", "--rm",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/verify.sh", "/magic_stick/build/$isoName")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestBoot") {
    group = "iso"
    description = "Test ISO boot in QEMU (BIOS + UEFI) inside Docker"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm",
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/test-boot.sh", "/magic_stick/build/$isoName", "120")
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
    commandLine("docker", "run", "--rm",
        "--device", device,
        "-v", "$projDir:/magic_stick",
        dockerImage,
        "/magic_stick/scripts/flash.sh", device)
    onlyIf { project.hasProperty("device") }
}