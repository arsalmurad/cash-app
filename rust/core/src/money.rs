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

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MoneyError {
    InvalidCurrencyCode(String),
    InvalidRate,
    Overflow,
}

impl fmt::Display for MoneyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
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
