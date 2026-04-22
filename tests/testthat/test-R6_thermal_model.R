# =============================================================================
# Tests: R6_thermal_model (T016)
# =============================================================================

test_that("calc_cop returns expected values at reference temperature", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # COP at reference T_ext: should be cop_nominal = 3.5
  expect_equal(tm$calc_cop(7), 3.5, tolerance = 0.01)
})

test_that("calc_cop increases with T_ext", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  expect_gt(tm$calc_cop(15), tm$calc_cop(7))
  expect_gt(tm$calc_cop(7), tm$calc_cop(-5))
})

test_that("calc_cop decreases with T_ballon above reference", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # Higher t_ballon = lower COP (harder to heat)
  expect_gt(tm$calc_cop(7, t_ballon = 45), tm$calc_cop(7, t_ballon = 55))
})

test_that("calc_cop is clamped to [1.5, 5.5]", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # Very cold: should be clamped at minimum
  expect_gte(tm$calc_cop(-30), 1.5)
  # Very warm: should be clamped at maximum
  expect_lte(tm$calc_cop(40), 5.5)
})

test_that("thermal_step: PAC OFF causes temperature drop", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # PAC OFF (load=0), no ECS draw: temperature drops from heat losses
  t_new <- tm$thermal_step(50, 0, 3.5, 0)
  expect_lt(t_new, 50)
})

test_that("thermal_step: PAC ON increases temperature", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # PAC ON (load=1), no ECS: temperature rises
  t_new <- tm$thermal_step(50, 1, 3.5, 0)
  expect_gt(t_new, 50)
})

test_that("thermal_step: ECS draw causes extra cooling", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # Same conditions but with ECS draw: lower temperature
  t_no_ecs <- tm$thermal_step(50, 0, 3.5, 0)
  t_with_ecs <- tm$thermal_step(50, 0, 3.5, 0.5)
  expect_lt(t_with_ecs, t_no_ecs)
})

test_that("thermal_step: result is clamped", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 100, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # Very high power should be clamped at t_max + 5
  t_new <- tm$thermal_step(50, 1, 5.0, 0)
  expect_lte(t_new, 60)  # t_max + 5
})

test_that("energy_balance computes correctly", {
  tm <- ThermalModel$new(list(
    p_pac_kw = 2, dt_h = 0.25, cop_nominal = 3.5, t_ref_cop = 7,
    capacite_kwh_par_degre = 200 * 0.001163, t_max = 55, t_min = 45
  ))

  # Surplus scenario: PV > consumption
  eb <- tm$energy_balance(pv = 3, conso = 1, pac_elec = 0.5)
  expect_equal(eb$offtake, 0)
  expect_equal(eb$intake, 1.5)

  # Deficit scenario: PV < consumption
  eb <- tm$energy_balance(pv = 1, conso = 2, pac_elec = 0.5)
  expect_equal(eb$offtake, 1.5)
  expect_equal(eb$intake, 0)
})
