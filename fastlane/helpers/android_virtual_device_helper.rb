module Fastlane
  module Helpers
    class TemporaryAndroidVirtualDevice
      attr_accessor :device_name
      attr_accessor :device_type
      attr_accessor :device_package
      attr_accessor :device_skin

      TEMPORARY_AVD_NAME = "fastlane-temporary-device".freeze

      def initialize(device_type: nil, device_package: nil, device_skin: nil)
        self.device_name = TEMPORARY_AVD_NAME
        self.device_type = device_type
        self.device_package = device_package
        self.device_skin = device_skin
      end

      def run
        create_avd
        device_serial = launch_avd

        begin
          yield(device_serial)
        ensure
          shutdown_device(device_serial)
          delete_avd
        end
      end

      private

      def shutdown_device(device_serial)
        killer = AndroidVirtualDeviceKiller.new
        killer.shutdown_device(device_serial)
      end

      def create_avd
        creater = AndroidVirtualDeviceCreater.new
        creater.trigger(device_name: device_name,
                        device_type: device_type,
                        device_package: device_package)
      end

      def launch_avd
        launcher = AndroidVirtualDeviceLauncher.new
        launcher.trigger(device_name: device_name,
                         device_skin: device_skin,
                         wipe_data: true)
      end

      def delete_avd
        deleter = AndroidVirtualDeviceDeleter.new
        deleter.trigger(device_name: device_name)
      end
    end

    module AndroidVirtualDevicePathHelper
      def self.android_home
        ENV['ANDROID_HOME'] || ENV['ANDROID_SDK_ROOT'] || ENV['ANDROID_SDK']
      end

      def self.default_avdmanager_path
        Pathname.new(android_home).join("tools/bin/avdmanager").to_s
      end

      def self.default_emulator_path
        Pathname.new(android_home).join("emulator/emulator").to_s
      end

      def self.default_sdkmanager_path
        Pathname.new(android_home).join("tools/bin/sdkmanager").to_s
      end
    end

    module AndroidVirtualDevicesAdbHelper
      def self.adb(command: nil, serial: "")
        Fastlane::Actions::AdbAction.run(command: command, serial: serial)
      end

      def self.adb_devices
        Fastlane::Actions::AdbDevicesAction.run({})
      end

      def self.adb_active_ports
        adb_devices.map { |device| device.serial.split("-").last.to_i }.sort
      end

      def self.boot_completed?(device_serial)
        adb(command: "shell getprop sys.boot_completed", serial: device_serial).to_i == 1
      end

      def self.wait_for_device(device_serial)
        adb(command: "wait-for-device", serial: device_serial)
      end

      def self.shutdown_device(device_serial)
        adb(command: "emu kill", serial: device_serial)
      end
    end

    class AndroidVirtualDeviceCreater
      attr_accessor :avdmanager_path
      attr_accessor :sdkmanager_path

      SDCARD_SIZE_MB = 128

      def initialize(avdmanager_path: nil, sdkmanager_path: nil)
        if avdmanager_path.nil?
          avdmanager_path = AndroidVirtualDevicePathHelper.default_avdmanager_path
        end
        self.avdmanager_path = avdmanager_path
        if sdkmanager_path.nil?
          sdkmanager_path = AndroidVirtualDevicePathHelper.default_sdkmanager_path
        end
        self.sdkmanager_path = sdkmanager_path
      end

      def trigger(device_name: nil, device_type: nil, device_package: nil)
        UI.message("Creating emulator '#{device_name}'")

        ensure_package_available(device_package)

        command = [
          avdmanager_path,
          "create avd",
          "--force",
          "--name \"#{device_name}\"",
          "--device \"#{device_type}\"",
          "--package \"#{device_package}\"",
          "--sdcard \"#{SDCARD_SIZE_MB}M\""
        ]
        Action.sh(command.join(" "))
      end

      private

      def ensure_package_available(device_package)
        Action.sh("echo y | #{sdkmanager_path} --verbose \"#{device_package}\"")
      end
    end

    class AndroidVirtualDeviceLauncher
      attr_accessor :emulator_path

      LAUNCH_TIMEOUT = 60
      LAUNCH_WAIT = 2

      # This is documented in https://developer.android.com/studio/run/emulator-commandline#common
      MIN_EMULATOR_PORT = 5554

      def initialize(emulator_path: nil)
        if emulator_path.nil?
          emulator_path = AndroidVirtualDevicePathHelper.default_emulator_path
        end
        self.emulator_path = emulator_path
      end

      def trigger(device_name: nil, wipe_data: false, device_skin: nil)
        port = next_available_port

        launch(device_name, wipe_data, device_skin, port)

        serial = "emulator-#{port}"
        wait_for_device_boot(serial)

        serial
      end

      private

      def next_available_port
        current_ports = AndroidVirtualDevicesAdbHelper.adb_active_ports
        return MIN_EMULATOR_PORT if current_ports.empty?
        current_ports.last + 2
      end

      def launch(device_name, wipe_data, device_skin, port)
        UI.message("Launching emulator '#{device_name}'")

        command = [
          emulator_path,
          "-avd \"#{device_name}\"",
          "-port #{port}",
          "-no-snapshot",
          "-gpu auto",
        ]
        command << "-wipe-data" if wipe_data
        unless device_skin.nil?
          command << "-skin"
          command << "\"#{device_skin}\""
        end
        command << "&" # Run in background
        joined_command = command.join(" ")

        UI.command(joined_command)
        system(joined_command)
      end

      def wait_for_device_boot(device_serial)
        AndroidVirtualDevicesAdbHelper.wait_for_device(device_serial)
        begin
          # Wait for complete boot
          Timeout::timeout(LAUNCH_TIMEOUT) do
            next if AndroidVirtualDevicesAdbHelper.boot_completed?(device_serial)
            until AndroidVirtualDevicesAdbHelper.boot_completed?(device_serial)
              sleep(LAUNCH_WAIT)
            end
          end
        rescue Timeout::Error
          UI.user_error!("Timed out waiting for the device to boot")
        end
      end
    end

    class AndroidVirtualDeviceDeleter
      attr_accessor :avdmanager_path

      def initialize(avdmanager_path: nil)
        if avdmanager_path.nil?
          avdmanager_path = AndroidVirtualDevicePathHelper.default_avdmanager_path
        end
        self.avdmanager_path = avdmanager_path
      end

      def trigger(device_name: nil)
        UI.message("Deleting emulator '#{device_name}'")
        Action.sh("#{avdmanager_path} delete avd --name #{device_name}")
      end
    end

    class AndroidVirtualDeviceKiller
      attr_accessor :emulator_path

      SHUTDOWN_TIMEOUT = 60
      SHUTDOWN_WAIT = 2

      def initialize(emulator_path: nil)
        if emulator_path.nil?
          emulator_path = AndroidVirtualDevicePathHelper.default_emulator_path
        end
        self.emulator_path = emulator_path
      end

      def shutdown_device(device_serial)
        UI.message("Shutting down '#{device_serial}'")

        AndroidVirtualDevicesAdbHelper.shutdown_device(device_serial)
        wait_for_shutdown(device_serial)
      end

      private

      def wait_for_shutdown(device_serial)
        begin
          Timeout::timeout(SHUTDOWN_TIMEOUT) do
            next if shutdown?(device_serial)
            until shutdown?(device_serial)
              sleep(SHUTDOWN_WAIT)
            end
          end
        rescue Timeout::Error
          UI.user_error!("Timed out waiting for '#{device_serial}' to shutdown")
        end
      end

      def shutdown?(device_serial)
        !AndroidVirtualDevicesAdbHelper.adb_devices.map(&:serial).include? device_serial
      end
    end
  end
end
