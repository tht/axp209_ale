defmodule Axp209Ale do
  @moduledoc """
  This module helps communicating with the AXP209 PMIC. This *Power Management IC* is mounted on the C.H.I.P. embedded computers.
  Make sure you start this Module as an Application to make it work. It will also monitor the state of the PMIC in background and
  allows to register for changes (not yet implemented!).
  """

  use Application
  use GenServer
  use Bitwise, only_operators: true
  require Logger

  @initial_interval 100
  @interval 10000

  def read_reg(addr) do
    GenServer.call __MODULE__, {:read_reg, addr}
  end

  def read_dreg(addr) do
    GenServer.call __MODULE__, {:read_dreg, addr}
  end

  def charge_current do
    GenServer.call __MODULE__, {:read_charge_current}
  end

  def discharge_current do
    GenServer.call __MODULE__, {:read_discharge_current}
  end

  def read_state do
    GenServer.call __MODULE__, {:read_state}
  end

  def setCurrentLimit(limit) do
    GenServer.cast __MODULE__, {:setLimit, limit}
  end



  def start_link({bus, addr}=args) do
    Logger.info "Starting for bus: #{bus} on address 0x#{addr |> Integer.to_char_list(16)}"
    GenServer.start_link(__MODULE__, args, name: Axp209Ale)
  end

  def init({bus, addr}) do
    {:ok, pid} = I2c.start_link(bus, addr)
    Process.link pid
    state = %{
      bus: bus,
      addr: addr,
      pid: pid
    }
    Process.send_after(self(), :timer, @initial_interval)
    {:ok, state}
  end

  defp read_reg(pid, addr) do
    << res :: size(8) >> = I2c.write_read(pid, <<addr>>, 1)
    res
  end

  defp read_dreg(pid, addr) do
    << msb::size(8), _::size(4), lsb::size(4) >> = I2c.write_read(pid, <<addr>>, 2)
    msb <<< 4 ||| lsb
  end
  
  defp to_bool(val, tr \\ true, fa \\ false) do
    case val do
      0 -> fa
      _ -> tr
    end
  end

  defp read_state(pid) do
    << _ac_pres :: size(1), _ac_inst :: size(1), _vbus_pres :: size(1), vbus_usea :: size(1),
       _vbus_ov :: size(1), bat_dir  :: size(1), _short     :: size(1), _boot_src :: size(1),
       ovr_temp :: size(1), charging :: size(1), battery    :: size(1), _ :: size(5) >> = all = I2c.write_read(pid, <<0x00>>, 2)
    Logger.debug "State: #{inspect all}"
    %{
      usb_power: to_bool(vbus_usea),
      bat_dir: to_bool(bat_dir, :in, :out),
      over_temp: to_bool(ovr_temp),
      charging: to_bool(charging),
      battery: to_bool(battery)
    }
  end

  def handle_call({:read_reg, addr}, _from, %{pid: pid} = state) do
    {:reply, read_reg(pid, addr), state}
  end

  def handle_call({:read_dreg, addr}, _from, %{pid: pid} = state) do
    {:reply, read_dreg(pid, addr), state}
  end

  def handle_call({:read_state}, _from, %{pid: pid} = state) do
    {:reply, read_state(pid), state}
  end


  def handle_call({:read_discharge_current}, _from, %{pid: pid} = state) do
    {:reply, round(0.5 * read_dreg pid, 0x7C), state}
  end

  def handle_call({:read_charge_current}, _from, %{pid: pid} = state) do
    {:reply, round(0.5 * read_dreg pid, 0x7A), state}
  end

  def handle_cast({:setLimit, mA}, %{pid: pid} = state) do
    val = cond do
      mA >= 1000 -> 0x63
      mA >=  900 -> 0x60
      mA >=  500 -> 0x61
      mA >=  100 -> 0x62
    end

    :ok = I2c.write(pid, <<0x30, val>>)
    {:noreply, state}
  end

  def handle_info(:timer, %{pid: pid} = state) do
    Logger.info "Checking power state..."
    res = %{battery: battery} = read_state(pid)
    Logger.info "#{inspect res}"
    if battery do
      Logger.info "Battery charge: #{round(1.1 * read_dreg pid, 0x78)}mV. In: #{round(0.5 * read_dreg pid, 0x7A)}mA, out: #{round(0.5 * read_dreg pid, 0x7C)}mA"
    end
    Process.send_after(self(), :timer, @interval)
    {:noreply, state}
  end


  @doc false
  def start(_type, args) do
    import Supervisor.Spec, warn: false

    Logger.info "Application supervisor is starting up..."
    children = [
      worker(__MODULE__, [args])
    ]
    Supervisor.start_link(children, [strategy: :one_for_one])
  end

end
