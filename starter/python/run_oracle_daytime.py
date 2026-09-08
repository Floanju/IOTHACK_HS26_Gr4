"""
run_oracle_daytime.py

Startet oracle_writer.py, versetzt die Simulationsuhr aber vorher direkt auf
sim_hour = 12 (Mittag) statt bei 0 (Mitternacht) zu beginnen. Nur fuers lokale
Testen gedacht, damit man nicht 24 reale Minuten auf Sonnenaufgang warten muss
(PV-Produktion ist in data_simulator.py nur zwischen sim_hour 6-20 > 0).

Fasst oracle_writer.py NICHT an - nur ein duenner Wrapper drumherum.
"""

from oracle_writer import OracleWriter

TARGET_SIM_HOUR = 12  # Mittag - maximale Einstrahlung

if __name__ == "__main__":
    writer = OracleWriter()

    # 1 reale Minute = 0.25 Sim-Stunden (siehe data_simulator.SIM_MINUTES_PER_SLOT)
    real_seconds_needed = (TARGET_SIM_HOUR / 0.25) * 60
    writer.simulator.start_real_time -= real_seconds_needed

    print(f"Simulationsuhr auf {TARGET_SIM_HOUR}:00 Uhr vorgestellt (nur lokales Testen).\n")
    writer.run()
