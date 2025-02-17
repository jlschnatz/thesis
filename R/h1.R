#!/usr/bin/env Rscript

# Install, load packages & functions ———————————————————————————————————————————————————————————————————————————————————       
if(!"pacman" %in% installed.packages()) {install.packages("pacman")}
pacman::p_load(
  sysfonts, showtext, here, tidyverse, betareg, latex2exp, broom, 
  marginaleffects, kableExtra,  insight, datawizard
  )
source(here("R/functions.R"))

# Add fonts ————————————————————————————————————————————————————————————————————————————————————————————————————————————
showtext_opts(dpi = 500)
font_add_google("Noto Sans Math", "font")
showtext_auto()

# Load data ————————————————————————————————————————————————————————————————————————————————————————————————————————————
data_meta <- read_csv(here("data/meta/processed/data_lindenhonekopp_proc.csv"))
data_optim <- read_csv(here("data/optim/processed/data_optim_merged.csv"))

# Beta-regression model specification: w_pbs ~ z_rs ————————————————————————————————————————————————————————————————————
data_model <- data_meta |> 
  # Filter only normal Meta-Analysis
  filter(type_synthesis == "ma") |> 
  # Fisher z-transformed Spearman correlation coefficient for each meta-analysis 
  group_by(id_meta) |> 
  summarise(z_rs = atanh(cor(n, abs(d), method = "spearman"))) |>
  # Join with optimization data
  left_join(data_optim, join_by(id_meta)) |> 
  select(id_meta, z_rs, w_pbs) 

# Fit model
mod_h1 <- betareg(
  formula = w_pbs ~ 1 + z_rs, 
  link = "logit",
  link.phi = "identity",
  data = data_model,
  control = betareg.control(method = "L-BFGS", trace = F)
  ) 

summary(mod_h1)
write_rds(mod_h1, here("data/src/model_h1.rds"))

# Generate scatter plot with model predictions —————————————————————————————————————————————————————————————————————————
predictions(mod_h1, by  = "z_rs", type = "response", conf_level = 0.95) |> 
  ggplot(aes(z_rs, y = estimate)) +
  geom_point(
    data = data_model, 
    mapping = aes(z_rs, w_pbs), 
    alpha = 0.4,
    color = "#051088"
    ) +
  geom_line(linewidth = .7, color = "#051088") +
  geom_ribbon(aes(ymin = conf.low, ymax = conf.high), alpha = 0.1, fill = "#051088")  +
  scale_y_continuous(
    name = TeX("$\\widehat{\\omega}_{PBS}$"),
    limits = c(0, 1),
    breaks = seq(0, 1, .2),
    expand = expansion(),
    ) +
  scale_x_continuous(
    name = TeX("Fisher z-transformed\nSpearman correlation $z_{r_S}$"),
    limits = c(-1.5, 1.5),
    breaks = seq(-1.5, 1.5, .5),
    expand = expansion()
  ) +
  sjPlot::theme_sjplot() +
  coord_cartesian(clip = "off") +
  theme(
    text = element_text(family = "font"),
    axis.title = element_text(size = 11),
    plot.margin = margin(5, 5, 5, 5, "mm"),
    axis.title.y = element_text(margin = margin(r = 0, unit = "mm")),
    axis.text.y = element_text(margin = margin(l = 0, unit = "mm"), size = 11),
    axis.title.x = element_text(margin = margin(t = 8, unit = "mm"))
    ) -> p

write_rds(p, file = here("data/src/plot_h1.rds"))

# Generate table with model results ————————————————————————————————————————————————————————————————————————————————————

# One-sided p-value: b1 > 0
z <- coef(mod_h1) / sqrt(diag(vcov(mod_h1)))
p_b1 <- pnorm(z[2], lower.tail = FALSE)

data_table <- tidy(mod_h1, conf.int = TRUE) |>
  # one-sided confidence interval for Delta^2 -> upper limits is 0
  mutate(conf.high = if_else(term == "z_rs", Inf, conf.high)) |>
  # recalculate lower CI for Delta^2
  mutate(conf.low = if_else(term == "z_rs", estimate + qnorm(0.05) * std.error, conf.low)) |>
  # transform CIs and estimate for log-OR to ORs
  mutate(across(c(estimate, conf.low, conf.high), exp)) |>
  mutate(ci = format_ci(conf.low, conf.high, ci_string = "", ci = NULL, digits = 2), .before = std.error) |>
  select(-starts_with("conf")) |>
  mutate(p.value = if_else(term == "z_rs", p_b1, p.value)) |>
  mutate(p.value = str_remove(format_p(p.value, name = NULL, digits = "apa"), "^0")) |>
  mutate(across(c(estimate, std.error, statistic), ~format_value(.x, digits = 2))) |>
  mutate(estimate = if_else(component == "mean", paste0("$", estimate, "^a$"), paste0("$", estimate, "^b$"))) |>
  mutate(ci = if_else(term == "z_rs", glue::glue("${ci}^c$"), ci)) |>
    mutate(term = case_match(term, 
  "(phi)" ~ "Intercept", 
  "(Intercept)" ~ "Intercept",
   "z_rs" ~ "$z_{r_s}$")
   ) |> 
  select(-component) |>
  mutate(ci = str_replace(ci, "Inf", "\\\\text{Inf}"))

table_h1 <- nice_table(
  x = data_table,
  caption = "Beta Regression Results for $\\hypothesis{1}{}$", 
  digits = 2,
  col_names = c("Term", "Estimate", "$CI$ (95\\%)", "$SE$", "$z$", "$p$"),
  general_fn = paste0("$CI$: Confidence interval, $SE$: standard error, ", report_fit(mod_h1, "w_pbs")),
  alphabet_fn = c("Odds ratio", "Raw values", "One-sided confidence interval in the direction of the hypothesis")
) |>
group_rows("Mean model component: $\\mu$", 1, 2, escape = FALSE, extra_latex_after = "\\\\[-1.5ex]") |>
group_rows("Precision model component: $\\phi$", 3, 3, escape = FALSE, extra_latex_after = "\\\\[-1.5ex]") |>
str_replace_all(string = _, pattern = "\\\\begin\\{tablenotes\\}", "\\\\begin\\{tablenotes\\}[flushleft]")

cat(table_h1, file = here("tables/table_h1.tex"))