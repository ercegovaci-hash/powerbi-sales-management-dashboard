# -----------------------------------------------------------------------------
# analysis.R - answers the four user stories with numbers, checks data quality,
# and produces the reference values used to validate the DAX measures.
#
# Run from the repository root:  Rscript analysis/R/analysis.R
# Input: the exported tables in ArrangedData/ (the same data the .pbix uses)
# -----------------------------------------------------------------------------

required <- c("data.table", "readxl", "ggplot2", "svglite", "scales")
missing  <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install: ", paste(missing, collapse = ", "))
suppressPackageStartupMessages({ library(data.table); library(ggplot2) })
options(width = 160)

out <- function(...) file.path("analysis", ...)
save_plot <- function(p, name, width = 8, height = 4.2) {
  ggsave(out("figures", paste0(name, ".svg")), p, width = width, height = height,
         device = svglite::svglite, bg = "white")
}
theme_set(theme_minimal(base_size = 11) +
            theme(plot.title = element_text(face = "bold"), panel.grid.minor = element_blank(),
                  plot.background = element_rect(fill = "white", colour = NA)))
eur <- scales::label_dollar(scale = 1e-6, suffix = "M", accuracy = 0.1)

# --- Load --------------------------------------------------------------------
sales <- fread("ArrangedData/Exported Data - FACT_InternetSales.csv")
cust  <- fread("ArrangedData/Exported Data - DIM_Customers.csv")
prod  <- fread("ArrangedData/Exported Data - DIM_Products.csv", na.strings = "NULL")
cal   <- fread("ArrangedData/Exported Data - DIM_Calendar.csv")
budget <- as.data.table(readxl::read_excel("ArrangedData/Sent Over Data - SalesBudget.xlsx"))
budget[, month := as.IDate(Date)]

sales[, date := as.IDate(as.character(OrderDateKey), format = "%Y%m%d")]
sales[, month := as.IDate(format(date, "%Y-%m-01"))]

sink(out("output", "analysis.txt"), split = TRUE)

# --- 0. Data quality checks --------------------------------------------------
cat("== Data quality ==\n")
cat(sprintf("Sales rows: %d | orders: %d | customers with sales: %d of %d | products sold: %d of %d\n",
            nrow(sales), uniqueN(sales$SalesOrderNumber), uniqueN(sales$CustomerKey), nrow(cust),
            uniqueN(sales$ProductKey), nrow(prod)))
cat(sprintf("Order dates: %s to %s | Calendar table: %s to %s | Budget: %s to %s\n",
            min(sales$date, na.rm = TRUE), max(sales$date, na.rm = TRUE), min(cal$Date), max(cal$Date),
            min(budget$month), format(max(budget$month), "%Y-%m")))

bad_keys <- sales[!OrderDateKey %in% cal$DateKey, .(rows = .N, sales = sum(SalesAmount)), by = OrderDateKey]
cat("\n1) Order dates that do not exist in the calendar table:\n"); print(bad_keys)

cat("\n2) Budget months without any sales data (dashboards would show -100% vs budget):\n")
bm <- merge(budget[, .(month, Budget)], sales[, .(sales = sum(SalesAmount)), by = month],
            by = "month", all.x = TRUE)
print(bm[is.na(sales) | sales < 0.1 * Budget, .(month = format(month, "%Y-%m"), Budget, sales)])

cat("\n3) Product Status values (SQL: ISNULL(Status, 'Outdated')):\n")
print(prod[, .N, by = `Product Status`])
cat("   'Outdated' is cut to 'Outdate': ISNULL returns the type of its first argument,\n",
    "  and DimProduct.Status is nvarchar(7). Fix: COALESCE(p.Status, 'Outdated').\n")

dup_names <- prod[, .(keys = .N), by = `Product Name`][keys > 1]
cat(sprintf("\n4) %d product names have more than one ProductKey (price history versions).\n",
            nrow(dup_names)))
cat("   Visuals grouped by Product Name add the versions together (correct for sales),\n",
    "  but a filter on ProductKey or ProductItemCode would split them.\n")

cat(sprintf("\n5) The SQL extract keeps OrderDateKey >= YEAR(GETDATE()) - 2. Run in %d it\n",
            as.integer(format(Sys.Date(), "%Y"))),
    sprintf("  returns orders from %d onward, i.e. nothing: the data ends in January 2021.\n",
            as.integer(format(Sys.Date(), "%Y")) - 2))

# --- Story 4: sales over time against budget ---------------------------------
cat("\n== Story 4: sales vs budget ==\n")
yearly <- sales[!is.na(date), .(sales = sum(SalesAmount)), by = .(year = year(date))][order(year)]
print(yearly)
b20 <- bm[format(month, "%Y") == "2020"]
b20[, `:=`(variance = sales - Budget, variance_pct = (sales - Budget) / Budget)]
print(b20[, .(month = format(month, "%Y-%m"), sales = round(sales), Budget,
              variance = round(variance), variance_pct = round(100 * variance_pct, 1))])
cat(sprintf("2020 total: sales %.2fM vs budget %.2fM -> %+.1f%%. Months above budget: %d of 12\n",
            sum(b20$sales) / 1e6, sum(b20$Budget) / 1e6,
            100 * (sum(b20$sales) / sum(b20$Budget) - 1), sum(b20$variance > 0)))
fwrite(b20, out("output", "sales_vs_budget_2020.csv"))

b20[, label := sprintf("%+.0f%%", 100 * variance_pct)]
p1 <- ggplot(b20, aes(month)) +
  geom_col(aes(y = sales, fill = variance > 0), width = 22) +
  geom_step(aes(y = Budget), direction = "mid", linewidth = 0.9, colour = "#1a202c") +
  geom_text(aes(y = pmax(sales, Budget), label = label), vjust = -0.5, size = 3.1) +
  scale_fill_manual(values = c(`TRUE` = "#2f855a", `FALSE` = "#c53030"),
                    labels = c(`TRUE` = "above budget", `FALSE` = "below budget")) +
  scale_y_continuous(labels = eur, expand = expansion(mult = c(0, 0.1))) +
  scale_x_date(date_labels = "%b", date_breaks = "1 month") +
  labs(title = "2020: internet sales vs budget by month",
       subtitle = "Bars = actual sales, black line = budget, label = variance",
       x = NULL, y = NULL, fill = NULL) +
  theme(legend.position = "top")
save_plot(p1, "01_sales_vs_budget_2020")

# --- Story 1 + 3: products --------------------------------------------------
cat("\n== Stories 1 and 3: products ==\n")
total <- sum(sales$SalesAmount)
by_cat <- merge(sales, prod, by = "ProductKey")[, .(sales = sum(SalesAmount)), by = `Product Category`]
by_cat[, share := round(100 * sales / total, 1)]
print(by_cat[order(-sales)])
by_prod <- merge(sales, prod, by = "ProductKey")[
  , .(sales = sum(SalesAmount), units = .N), by = .(`Product Name`, `Product Category`)][order(-sales)]
by_prod[, cum_share := cumsum(sales) / total]
cat(sprintf("Products sold: %d. Top 10 = %.1f%% of revenue. %d products make 80%% of revenue.\n",
            nrow(by_prod), 100 * sum(by_prod$sales[1:10]) / total,
            which(by_prod$cum_share >= 0.8)[1]))
print(head(by_prod[, .(`Product Name`, `Product Category`, sales = round(sales), units)], 10))
fwrite(by_prod, out("output", "sales_by_product.csv"))

top <- head(by_prod, 15)
top[, `Product Name` := factor(`Product Name`, levels = rev(`Product Name`))]
p3 <- ggplot(top, aes(sales, `Product Name`, fill = `Product Category`)) +
  geom_col(width = 0.7) +
  scale_x_continuous(labels = eur) +
  scale_fill_manual(values = c(Bikes = "#2b6cb0", Accessories = "#d69e2e", Clothing = "#805ad5")) +
  labs(title = "Top 15 products by revenue, 2019 - Jan 2021",
       subtitle = sprintf("Bikes = %.0f%% of revenue; the Mountain-200 family alone tops the list",
                          by_cat[`Product Category` == "Bikes", share]),
       x = NULL, y = NULL, fill = NULL) +
  theme(legend.position = "top")
save_plot(p3, "02_top_products", height = 4.6)

# --- Story 1 + 2: customers -------------------------------------------------
cat("\n== Stories 1 and 2: customers ==\n")
by_cust <- sales[, .(sales = sum(SalesAmount), orders = uniqueN(SalesOrderNumber)),
                 by = CustomerKey][order(-sales)]
by_cust[, cum_share := cumsum(sales) / total]
n <- nrow(by_cust)
cat(sprintf("Customers: %d. Top 10 = %.1f%%, top 1%% = %.1f%%, top 20%% = %.1f%% of revenue.\n",
            n, 100 * sum(by_cust$sales[1:10]) / total,
            100 * by_cust$cum_share[ceiling(0.01 * n)], 100 * by_cust$cum_share[ceiling(0.2 * n)]))
cat(sprintf("Orders per customer: mean %.2f. One order only: %.1f%% of customers.\n",
            mean(by_cust$orders), 100 * mean(by_cust$orders == 1)))

# Cross-sell: bike buyers who never bought an accessory or clothing
sp <- merge(sales, prod[, .(ProductKey, `Product Category`)], by = "ProductKey")
cats <- sp[, .(bikes = any(`Product Category` == "Bikes"),
               extras = any(`Product Category` %in% c("Accessories", "Clothing"))), by = CustomerKey]
cat(sprintf("Bike buyers: %d. Of them, %.1f%% never bought accessories or clothing.\n",
            sum(cats$bikes), 100 * mean(!cats[bikes == TRUE]$extras)))

by_city <- merge(sales, cust, by = "CustomerKey")[, .(sales = sum(SalesAmount)), by = `Customer City`][order(-sales)]
cat("Top 5 cities:\n"); print(head(by_city, 5))
fwrite(by_cust, out("output", "sales_by_customer.csv"))

lor <- data.table(cust_share = seq_len(n) / n, rev_share = by_cust$cum_share)[
  unique(c(seq(1, n, by = 50), n))]
p2 <- ggplot(lor, aes(cust_share, rev_share)) +
  geom_abline(linetype = "dotted") +
  geom_line(linewidth = 1, colour = "#2b6cb0") +
  annotate("point", x = 0.2, y = by_cust$cum_share[ceiling(0.2 * n)], size = 3, colour = "#c53030") +
  annotate("text", x = 0.22, y = by_cust$cum_share[ceiling(0.2 * n)] - 0.04, hjust = 0, size = 3.3,
           label = sprintf("top 20%% of customers = %.0f%% of revenue",
                           100 * by_cust$cum_share[ceiling(0.2 * n)])) +
  scale_x_continuous(labels = scales::percent) + scale_y_continuous(labels = scales::percent) +
  labs(title = "No single customer matters much: the top 10 bring 0.5% of revenue",
       subtitle = sprintf("%.0f%% of customers ordered only once - the growth lever is repeat purchases",
                          100 * mean(by_cust$orders == 1)),
       x = "Share of customers (ranked by revenue)", y = "Cumulative share of revenue")
save_plot(p2, "03_customer_concentration")

# --- Reference values for the DAX time-intelligence measures ----------------
cat("\n== Expected values for the DAX measures (check the Power BI matrix against these) ==\n")
ms <- sales[!is.na(date), .(Sales = sum(SalesAmount)), by = month][order(month)]
ms <- merge(data.table(month = seq(as.IDate("2019-01-01"), as.IDate("2021-01-01"), by = "month")),
            ms, by = "month", all.x = TRUE)
ms[is.na(Sales), Sales := 0]
ms[, year := year(month)]
ms[, `Sales YTD` := cumsum(Sales), by = year]
ms[, `Sales PY` := shift(Sales, 12)]
ms[, `YoY %` := round(100 * (Sales / `Sales PY` - 1), 1)]
ms[, `Sales 3M Avg` := round(frollmean(Sales, 3), 0)]
ms <- merge(ms, budget[, .(month, Budget)], by = "month", all.x = TRUE)
ms[, `Budget Var %` := round(100 * (Sales / Budget - 1), 1)]
ref <- ms[year == 2020, .(month = format(month, "%Y-%m"), Sales = round(Sales), `Sales YTD` = round(`Sales YTD`),
                          `Sales PY` = round(`Sales PY`), `YoY %`, `Sales 3M Avg`, Budget, `Budget Var %`)]
print(ref)
fwrite(ref, out("output", "dax_reference_values_2020.csv"))
sink()
