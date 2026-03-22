defmodule KomunBackend.Auth.Guardian do
  use Guardian, otp_app: :komun_backend

  alias KomunBackend.Accounts

  @impl true
  def subject_for_token(%{id: id}, _claims), do: {:ok, to_string(id)}
  def subject_for_token(_, _), do: {:error, :invalid_resource}

  @impl true
  def resource_from_claims(%{"sub" => id}) do
    case Accounts.get_user(id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def resource_from_claims(_), do: {:error, :invalid_claims}

  # Convenience: encode and sign with extra claims
  def sign_in(user) do
    extra_claims = %{
      "user_id" => user.id,
      "email" => user.email,
      "role" => user.role
    }

    encode_and_sign(user, extra_claims)
  end
end
