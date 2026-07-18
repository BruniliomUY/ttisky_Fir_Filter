# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# Misma frecuencia que asume el diseño (config.json: CLOCK_PERIOD = 40ns -> 25 MHz)
CLK_PERIOD_NS = 40

# Debe coincidir con el DIVIDER calculado en tt_um_bruniliomuy_top.v
# (CLK_HZ / SAMPLE_HZ = 25_000_000 / 8_000)
SAMPLE_DIVIDER = 25_000_000 // 8_000

# Debe coincidir con BAUD_DIVIDER en tt_um_bruniliomuy_top.v
# (CLK_HZ / BAUD = 25_000_000 / 115200)
BAUD_DIVIDER = 25_000_000 // 115_200

FILTER_HIGHPASS = 0b00
FILTER_LOWPASS  = 0b01
FILTER_BANDPASS = 0b10  # antes mal etiquetado como FILTER_ALLPASS
FILTER_ALLPASS  = 0b11  # antes mal etiquetado como FILTER_NOTCH
# NOTA: filtro_fir.v solo implementa 4 bancos (ver comentario de cabecera
# del archivo): highpass, lowpass, bandpass, allpass. No existe un banco
# "notch" en el RTL; el nombre FILTER_NOTCH de una version anterior de este
# test no correspondia a nada real y quedaba mapeado, por error, al banco
# allpass verdadero (sel=3).


def to_signed8(raw):
    """Convierte un valor crudo (0-255) a entero con signo de 8 bits (complemento a 2)."""
    raw = int(raw)
    if raw >= 128:
        raw -= 256
    return raw


async def start_clock(dut):
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())


async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


def set_filter(dut, sel):
    # i_filter_sel se lee de uio_in[2:1]; el resto de uio_in queda en 0
    dut.uio_in.value = (sel & 0b11) << 1


async def settle_filter(dut, value, cycles_of_sample_tick=20):
    """Aplica `value` en ui_in y espera suficientes sample_ticks para que
    el shift register de 15 taps quede lleno con el mismo valor, más un
    margen de ciclos de clock para que el pipeline combinacional
    (prod_d/sum_d/sum3_d) termine de propagar."""
    dut.ui_in.value = value
    for _ in range(cycles_of_sample_tick):
        await ClockCycles(dut.clk, SAMPLE_DIVIDER)
    await ClockCycles(dut.clk, 10)


@cocotb.test()
async def test_reset_no_x(dut):
    """Tras el reset, las salidas no deben quedar en X/Z."""
    dut._log.info("Start")
    await start_clock(dut)
    await reset_dut(dut)
    await ClockCycles(dut.clk, 10)

    assert "x" not in str(dut.uo_out.value).lower(), (
        "uo_out quedo en X/Z despues del reset"
    )


@cocotb.test()
async def test_allpass_tracks_input(dut):
    """
    Con i_filter_sel = ALLPASS (banco con un solo coeficiente ~1.0 en el tap 0),
    la salida del FIR deberia seguir de cerca a la entrada una vez estabilizado
    el pipeline. Es el modo mas simple de validar sin depender de la convencion
    exacta de bits fraccionarios de SatTruncFP (que todavia hay que confirmar).
    """
    await start_clock(dut)
    await reset_dut(dut)
    set_filter(dut, FILTER_ALLPASS)

    test_value = 40  # muestra de entrada (Q1.7 ~ 0.3125)
    await settle_filter(dut, test_value)

    # NOTA: la instancia del DUT en tb.v se llama "fir_filter", no "user_project".
    fir_out = to_signed8(dut.fir_filter.fir_output.value)
    dut._log.info(f"fir_output (allpass) = {fir_out}, esperado ~ {test_value}")

    # Tolerancia amplia a proposito: solo confirmamos que sigue la entrada,
    # no un valor exacto de bit. Si esto falla por mucho, revisar el escalado
    # de SatTruncFP (ver conversacion sobre NBF_XI).
    assert abs(fir_out - test_value) <= 4, (
        f"El modo allpass deberia devolver ~{test_value}, se obtuvo {fir_out}"
    )


@cocotb.test()
async def test_filter_select_changes_output(dut):
    """Cambiar i_filter_sel con la misma entrada constante debe cambiar la
    salida del FIR: confirma que el mux de bancos de coeficientes esta
    realmente conectado (y no, por ejemplo, encavado en un solo banco)."""
    await start_clock(dut)

    outputs = {}
    for sel, name in [
        (FILTER_HIGHPASS, "highpass"),
        (FILTER_LOWPASS, "lowpass"),
        (FILTER_BANDPASS, "bandpass"),
        (FILTER_ALLPASS, "allpass"),
    ]:
        await reset_dut(dut)
        set_filter(dut, sel)
        await settle_filter(dut, 40)
        outputs[name] = to_signed8(dut.fir_filter.fir_output.value)
        dut._log.info(f"fir_output ({name}) = {outputs[name]}")

    assert len(set(outputs.values())) > 1, (
        f"Todos los modos dieron la misma salida ({outputs}); "
        "revisar el generate/mux de i_filter_sel en filtro_fir.v"
    )


@cocotb.test()
async def test_vga_sync_toggles(dut):
    """hsync debe alternar en algun momento: confirma que hvsync_generator corre.

    NOTA: si el modulo VGA fue removido del top (ver comentario en
    tt_um_bruniliomuy_top.v: "VGA removido por area"), este test ya no aplica
    y deberia eliminarse o saltarse (pytest.skip), en vez de fallar.
    """
    await start_clock(dut)
    await reset_dut(dut)

    if not hasattr(dut.fir_filter, "hsync_w"):
        dut._log.warning(
            "hsync_w no existe en el DUT (VGA removido del diseño); "
            "test omitido."
        )
        return

    seen = set()
    for _ in range(5000):
        await ClockCycles(dut.clk, 1)
        seen.add(int(dut.fir_filter.hsync_w.value))
        if len(seen) > 1:
            break

    assert len(seen) > 1, "hsync nunca cambio de valor en 5000 ciclos: revisar hvsync_generator"


@cocotb.test()
async def test_uart_tx_activity(dut):
    """Confirma actividad en la linea TX (uio_out[0]) tras varias muestras.

    Muestreamos con paso FINO (bien por debajo del periodo de baud_tick,
    ~217 ciclos de clk) durante varios periodos de sample_tick completos.
    El test anterior solo miraba uio_out una vez por cada sample_tick
    (cada 3125 ciclos), pero un frame UART completo (start+8 datos+stop =
    10 bits = ~2170 ciclos) termina ANTES de que llegue el siguiente
    sample_tick, dejando ~955 ciclos de linea inactiva (tx=1) en cada
    periodo. Si el punto de muestreo caia siempre en esa ventana inactiva,
    el test fallaba por aliasing, no porque el UART estuviera roto.
    """
    await start_clock(dut)
    await reset_dut(dut)
    dut.ui_in.value = 60

    seen = set()
    step = max(1, BAUD_DIVIDER // 20)          # paso fino, << periodo de baud_tick
    total_cycles = SAMPLE_DIVIDER * 3           # cubrir >2 periodos de muestra completos

    for _ in range(total_cycles // step):
        await ClockCycles(dut.clk, step)
        seen.add(int(dut.uio_out.value) & 0b1)

    assert len(seen) > 1, (
        "TX nunca cambio de nivel en varios periodos de muestreo; "
        "revisar baud_tick / wr_en en el transmitter"
    )
