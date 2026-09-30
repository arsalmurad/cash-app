use std::fmt;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Currency {
    code: [u8; 3],
    exponent: u8,
}

impl Currency {
    pub fn from_code(code: &str) -> Result<Self, MoneyError> {
        let bytes = code.as_bytes();
        if bytes.len() != 3 || !bytes.iter().all(u8::is_ascii_uppercase) {
            return Err(MoneyError::InvalidCurrencyCode(code.to_owned()));
        }

        let exponent = match code {
            // ISO 4217 active zero-decimal currencies and fund units.
            "BIF" | "CLP" | "DJF" | "GNF" | "ISK" | "JPY" | "KMF" | "KRW" | "PYG" | "RWF"
            | "UGX" | "UYI" | "VND" | "VUV" | "XAF" | "XOF" | "XPF" => 0,
            "BHD" | "IQD" | "JOD" | "KWD" | "LYD" | "OMR" | "TND" => 3,
            "CLF" => 4,
            _ => 2,
        };

        Ok(Self {
            code: [bytes[0], bytes[1], bytes[2]],
            exponent,
        })
    }

    pub fn code(&self) -> &str {
        std::str::from_utf8(&self.code).expect("currency codes are validated ASCII")
    }

    pub const fn exponent(&self) -> u8 {
        self.exponent
    }

    pub fn parse_major_units(&self, value: &str) -> Result<i64, MoneyError> {
        let value = value.trim();
        if value.is_empty() {
            return Err(MoneyError::InvalidAmount(value.to_owned()));
        }

        let (negative, unsigned) = match value.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, value),
        };
        let mut parts = unsigned.split('.');
        let major = parts.next().unwrap_or_default();
        let fraction = parts.next();
        if parts.next().is_some()
            || major.is_empty()
            || !major.bytes().all(|byte| byte.is_ascii_digit())
            || fraction.is_some_and(|digits| !digits.bytes().all(|byte| byte.is_ascii_digit()))
        {
            return Err(MoneyError::InvalidAmount(value.to_owned()));
        }

        let fraction = fraction.unwrap_or_default();
        if fraction.len() > usize::from(self.exponent)
            || (self.exponent == 0 && !fraction.is_empty())
        {
            return Err(MoneyError::InvalidAmount(value.to_owned()));
        }

        let scale = 10_i128.pow(u32::from(self.exponent));
        let major: i128 = major
            .parse()
            .map_err(|_| MoneyError::InvalidAmount(value.to_owned()))?;
        let mut fractional_minor: i128 = if fraction.is_empty() {
            0
        } else {
            fraction
                .parse()
                .map_err(|_| MoneyError::InvalidAmount(value.to_owned()))?
        };
        for _ in fraction.len()..usize::from(self.exponent) {
            fractional_minor = fractional_minor
                .checked_mul(10)
                .ok_or(MoneyError::Overflow)?;
        }
        let unsigned_minor = major
            .checked_mul(scale)
            .and_then(|scaled| scaled.checked_add(fractional_minor))
            .ok_or(MoneyError::Overflow)?;
        let signed_minor = if negative {
            unsigned_minor.checked_neg().ok_or(MoneyError::Overflow)?
        } else {
            unsigned_minor
        };
        i64::try_from(signed_minor).map_err(|_| MoneyError::Overflow)
    }

    pub fn format_minor_units(&self, minor_units: i64) -> String {
        if self.exponent == 0 {
            return format!("{} {minor_units}", self.code());
        }

        let negative = minor_units.is_negative();
        let absolute = i128::from(minor_units).abs();
        let scale = 10_i128.pow(u32::from(self.exponent));
        let major = absolute / scale;
        let minor = absolute % scale;
        let sign = if negative { "-" } else { "" };
        format!(
            "{} {sign}{major}.{minor:0width$}",
            self.code(),
            width = usize::from(self.exponent)
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Money {
    pub minor_units: i64,
    pub currency: Currency,
}

impl Money {
    pub const fn new(minor_units: i64, currency: Currency) -> Self {
        Self {
            minor_units,
            currency,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RoundingRule {
    HalfAwayFromZero,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FxRate {
    /// Target minor units per source minor unit, as an exact ratio.
    pub numerator: i64,
    pub denominator: i64,
    pub target_currency: Currency,
    pub rounding: RoundingRule,
}

impl FxRate {
    pub fn new(
        numerator: i64,
        denominator: i64,
        target_currency: Currency,
    ) -> Result<Self, MoneyError> {
        if numerator <= 0 || denominator <= 0 {
            return Err(MoneyError::InvalidRate);
        }
        Ok(Self {
            numerator,
            denominator,
            target_currency,
            rounding: RoundingRule::HalfAwayFromZero,
        })
    }

    /// Builds the exact rate for a user-entered decimal such as `"1.0842"`,
    /// meaning one *major* unit of `source` is worth that many *major* units
    /// of `target`. The stored ratio is per *minor* unit, so it is scaled by
    /// both currencies' exponents (1 JPY = 0.0067 USD is 67/100, not 67/10000)
    /// and reduced to lowest terms. Integer arithmetic only: no float ever
    /// touches a rate.
    pub fn from_decimal_rate(
        rate: &str,
        source: &Currency,
        target: Currency,
    ) -> Result<Self, MoneyError> {
        let trimmed = rate.trim();
        let (whole, fraction) = trimmed.split_once('.').unwrap_or((trimmed, ""));
        let digits_only = |text: &str| text.bytes().all(|byte| byte.is_ascii_digit());
        if whole.is_empty()
            || !digits_only(whole)
            || (trimmed.contains('.') && (fraction.is_empty() || !digits_only(fraction)))
        {
            return Err(MoneyError::InvalidAmount(trimmed.to_owned()));
        }

        let mantissa: i128 = format!("{whole}{fraction}")
            .parse()
            .map_err(|_| MoneyError::Overflow)?;
        if mantissa == 0 {
            return Err(MoneyError::InvalidRate);
        }

        let fraction_digits = u32::try_from(fraction.len()).map_err(|_| MoneyError::Overflow)?;
        let power_of_ten = |exponent: u32| {
            10_i128
                .checked_pow(exponent)
                .ok_or(MoneyError::Overflow)
        };
        let numerator = mantissa
            .checked_mul(power_of_ten(u32::from(target.exponent))?)
            .ok_or(MoneyError::Overflow)?;
        let denominator = power_of_ten(fraction_digits)?
            .checked_mul(power_of_ten(u32::from(source.exponent))?)
            .ok_or(MoneyError::Overflow)?;

        let divisor = greatest_common_divisor(numerator, denominator);
        let numerator = i64::try_from(numerator / divisor).map_err(|_| MoneyError::Overflow)?;
        let denominator =
            i64::try_from(denominator / divisor).map_err(|_| MoneyError::Overflow)?;
        Self::new(numerator, denominator, target)
    }

    pub fn identity(currency: Currency) -> Self {
        Self {
            numerator: 1,
            denominator: 1,
            target_currency: currency,
            rounding: RoundingRule::HalfAwayFromZero,
        }
    }

    pub fn convert_minor_units(&self, source_minor_units: i64) -> Result<i64, MoneyError> {
        let product = i128::from(source_minor_units)
            .checked_mul(i128::from(self.numerator))
            .ok_or(MoneyError::Overflow)?;
        let denominator = i128::from(self.denominator);
        let quotient = product / denominator;
        let remainder = product % denominator;
        let rounded = match self.rounding {
            RoundingRule::HalfAwayFromZero => {
                let twice_remainder = remainder.abs().checked_mul(2).ok_or(MoneyError::Overflow)?;
                if twice_remainder >= denominator {
                    quotient + product.signum()
                } else {
                    quotient
                }
            }
        };
        i64::try_from(rounded).map_err(|_| MoneyError::Overflow)
    }
}

fn greatest_common_divisor(mut left: i128, mut right: i128) -> i128 {
    while right != 0 {
        (left, right) = (right, left % right);
    }
    left
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MoneyError {
    InvalidAmount(String),
    InvalidCurrencyCode(String),
    InvalidRate,
    Overflow,
}

impl fmt::Display for MoneyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidAmount(value) => write!(formatter, "invalid money amount: {value}"),
            Self::InvalidCurrencyCode(code) => {
                write!(formatter, "invalid ISO currency code: {code}")
            }
            Self::InvalidRate => formatter.write_str("FX rate components must be positive"),
            Self::Overflow => {
                formatter.write_str("money calculation overflowed signed 64-bit minor units")
            }
        }
    }
}

impl std::error::Error for MoneyError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn usd() -> Currency {
        Currency::from_code("USD").unwrap()
    }
    fn eur() -> Currency {
        Currency::from_code("EUR").unwrap()
    }
    fn jpy() -> Currency {
        Currency::from_code("JPY").unwrap()
    }

    #[test]
    fn a_decimal_rate_becomes_an_exact_reduced_ratio() {
        let rate = FxRate::from_decimal_rate("1.0842", &eur(), usd()).unwrap();
        assert_eq!((rate.numerator, rate.denominator), (5421, 5000));
        assert_eq!(rate.target_currency, usd());
        // EUR 100.00 -> USD 108.42, exactly.
        assert_eq!(rate.convert_minor_units(10_000).unwrap(), 10_842);
    }

    #[test]
    fn a_rate_from_a_zero_decimal_currency_accounts_for_the_exponent_gap() {
        // 1 JPY = 0.0067 USD, so JPY 1000 is USD 6.70 (670 cents).
        let rate = FxRate::from_decimal_rate("0.0067", &jpy(), usd()).unwrap();
        assert_eq!(rate.convert_minor_units(1_000).unwrap(), 670);
    }

    #[test]
    fn a_rate_into_a_zero_decimal_currency_accounts_for_the_exponent_gap() {
        // 1 USD = 150 JPY, so USD 100.00 (10000 cents) is JPY 15000.
        let rate = FxRate::from_decimal_rate("150", &usd(), jpy()).unwrap();
        assert_eq!(rate.convert_minor_units(10_000).unwrap(), 15_000);
    }

    #[test]
    fn a_same_currency_rate_of_one_is_the_identity() {
        let rate = FxRate::from_decimal_rate("1", &usd(), usd()).unwrap();
        assert_eq!((rate.numerator, rate.denominator), (1, 1));
    }

    #[test]
    fn surrounding_whitespace_is_ignored() {
        let rate = FxRate::from_decimal_rate("  1.5 ", &eur(), usd()).unwrap();
        assert_eq!((rate.numerator, rate.denominator), (3, 2));
    }

    #[test]
    fn malformed_zero_and_negative_rates_are_rejected() {
        for bad in [
            "", " ", "0", "0.000", "-1.5", "1.2.3", "abc", "1e5", ".5", "1.", "+1", "1,5",
        ] {
            assert!(
                FxRate::from_decimal_rate(bad, &eur(), usd()).is_err(),
                "{bad:?} should be rejected"
            );
        }
    }

    #[test]
    fn a_rate_too_large_for_64_bits_is_an_overflow_not_a_wrong_answer() {
        let error = FxRate::from_decimal_rate("99999999999999999999", &eur(), usd()).unwrap_err();
        assert_eq!(error, MoneyError::Overflow);
        let error = FxRate::from_decimal_rate(&format!("0.{}1", "0".repeat(60)), &eur(), usd())
            .unwrap_err();
        assert_eq!(error, MoneyError::Overflow);
    }
}
